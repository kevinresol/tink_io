package tink.io;

import haxe.io.*;

using tink.CoreApi;

@:forward
abstract Sink(SinkObject) to SinkObject from SinkObject {
  
  #if nodejs
  static public function ofNodeStream(w:js.node.stream.Writable.IWritable, name):Sink
    return new NodeSink(w, name);
  #end
    
  static public function async(writer, closer):Sink
    return new AsyncSink(writer, closer);
  
  @:from static public function flatten(s:Surprise<Sink, Error>):Sink
    return new FutureSink(s);
  
  static public function ofOutput(name:String, target:Output, ?worker:Worker):Sink
    return new StdSink(name, target, worker);
    
}

#if nodejs
class NodeSink extends AsyncSink {
  var target:js.node.stream.Writable.IWritable;
  var name:String;
  public function new(target, name) {
    this.target = target;
    this.name = name;
    super(
      function (from:Buffer) { 
        var bytes = from.content();
        var progress = from.writeTo( { writeBytes: function (b, pos, len) return len } );
        var native = untyped global.Buffer(bytes.getData());//TODO: find a nicer way to do this
        return 
          if (progress.isEof || target.write(native)) 
            Future.sync(Success(progress));
          else
            Future.async(function (cb) 
              next({
                drain: function (_) cb(Success(progress)),
                error: function (e) cb(Failure(new Error('Failed writing to $name', e))),
              })
            );
      },
      function () {
        target.end();
        return Future.sync(Success(Noise));
      }
    );
  }
  
  public function toString()
    return name;
  
  function next(handlers:Dynamic<Dynamic->Void>) {
    
    var handlers:haxe.DynamicAccess<Dynamic->Void> = handlers;
    
    function removeAll() {
      for (key in handlers.keys())
        target.removeListener(key, handlers[key]);
    }
    
    for (key in handlers.keys()) {
      var old = handlers[key];
      var nu = handlers[key] = function (x) {
        old(x);
        removeAll();
      }
      target.addListener(key, nu);
    }
    
  }  
}
#end

class AsyncSink implements SinkObject {
  
  var closer:Void->Surprise<Noise, Error>;
  var closing:Surprise<Noise, Error>;
  var writer:Buffer->Surprise<Progress, Error>;
  var last:Surprise<Progress, Error>;
  
  public function new(writer, closer) {
    this.closer = closer;
    this.writer = writer;
    last = Future.sync(Success(Progress.NONE));
  }
  
  public function write(from:Buffer) {
    if (closing != null)
      return Future.sync(Success(Progress.EOF));
    
    return cause(last = last >> function (p:Progress) {
      return writer(from);
    });
  }
  
  static function cause<A>(f:Future<A>) {
    f.handle(function () { } );
    return f;
  }
  
  public function close() {
    if (closing == null) 
      cause(closing = last.flatMap(function (_) return closer()));
    
    return closing;
  }
}

class FutureSink implements SinkObject {
  var f:Surprise<Sink, Error>;
  
  public function new(f)
    this.f = f;
    
  static function cause<A>(f:Future<A>) {
    f.handle(function () { } );
    return f;
  }
    
  public function write(from:Buffer):Surprise<Progress, Error> 
    return cause(f >> function (s:Sink) return s.write(from));
  
  public function close() 
    return cause(f >> function (s:Sink) return s.close());
  
  public function toString() {
    var ret = 'PENDING';
    f.handle(function (o) ret = Std.string(o));
    return '[FutureSink $ret]';
  }  
}

class StdSink implements SinkObject {
  
  var name:String;
  var target:Output;
  var worker:Worker;  
  
  public function new(name, target, ?worker) {
    this.name = name;
    this.target = target;
    this.worker = worker;
  }
    
  public function write(from:Buffer):Surprise<Progress, Error> 
    return worker.work(function () return from.tryWritingTo(name, target));
  
  public function close() {
    return 
      worker.work(function () 
        return Error.catchExceptions(
          function () {
            target.close();
            return Noise;
          },
          Error.reporter('Failed to close $name')
        )
      );
  }
  
  public function toString() {
    return name;
  }
  
}

interface SinkObject {
  /**
   * Writes bytes to this sink.
   * Note that a Progress.EOF can mean two things:
   * 
   * - depletion of a readonly buffer, which is the case if `from.available == 0 && !from.writable`
   * - end of the sink itself
   */
	function write(from:Buffer):Surprise<Progress, Error>;
	function close():Surprise<Noise, Error>;  
}

class ParserSink<T> implements SinkObject {
  
  var parser:StreamParser<T>;
  var state:Outcome<Progress, Error>;
  var onResult:T->Future<Bool>;
  var wait:Future<Bool>;
  
  public function new(parser, onResult) {
    this.parser = parser;
    this.onResult = onResult;
    this.wait = Future.sync(true);
  }
  
  function doClose()
    if (state == null)
      state = Success(Progress.EOF);
  
  public function write(from:Buffer):Surprise<Progress, Error>
    return
      if (this.state != null)
        Future.sync(this.state);
      else
        this.wait.map(function (resume) 
          return
            if (!resume) {
              doClose();
              state;
            }
            else {
              
              var last = from.available;
              
              switch parser.progress(from) {
                case Success(d):
                  
                  switch d {
                    case Some(v):
                      this.wait = onResult(v);
                    case None:
                  }
                  
                  Success(Progress.by(last - from.available));
                  
                case Failure(f):
                  Failure(f);
              }
            }
        );
  
	public function close():Surprise<Noise, Error> {
    doClose();
    return Future.sync(Success(Noise));
  }
}
