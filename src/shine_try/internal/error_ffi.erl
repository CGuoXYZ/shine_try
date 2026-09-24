-module(error_ffi).
-export([try_func/1, defer_func/2, on_crash_func/2]).

try_func(Func) ->
    try Func() of
        Val -> {ok, Val}
    catch
        Class:Reason:Stacktrace -> {error, {Class, Reason, Stacktrace}}
    end.

defer_func(Clean, Body) -> 
    try Body()
    after Clean()
    end.

on_crash_func(Clean, Body) -> 
    try Body() of
        Return -> Return
    catch
        Class:Reason:Stacktrace -> Clean(), erlang:raise(Class, Reason, Stacktrace)
    end.
