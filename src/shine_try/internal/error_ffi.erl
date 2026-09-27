-module(error_ffi).
-export([try_func/1, defer/2, on_crash/2]).

try_func(Func) ->
    try {ok, Func()}
    catch 
        Class:Reason:Stacktrace -> {error, {exception, Class, Reason, Stacktrace}}
    end.

defer(Clean, Body) -> 
    try Body()
    after Clean()
    end.

on_crash(Clean, Body) -> 
    try Body()
    catch 
        Class:Reason:Stacktrace -> Clean(), erlang:raise(Class, Reason, Stacktrace)
    end.
