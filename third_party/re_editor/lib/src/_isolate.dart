part of re_editor;
typedef IsolateRunnable<Req, Res> = Res Function(Req req);
typedef IsolateCallback<Res> = void Function(Res res);
class _IsolateTasker<Req, Res> {
  final String name;
  final IsolateRunnable<Req,Res> _runnable;
  bool _closed=false;
  int _generation=0;
  _IsolateTasker(this.name,this._runnable);
  void run(Req req, IsolateCallback<Res> callback) async {
    final generation=++_generation;
    final result=await compute(_runnable,req,debugLabel:name);
    if(!_closed && generation==_generation)callback(result);
  }
  void close(){_closed=true;_generation++;}
}
