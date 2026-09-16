-module(error_ffi).
-export([try_func/1]).

try_func(Func) ->
    try Func() of
        Val -> {ok, Val}
    catch
        Class:Reason:Stacktrace -> {error, {Class, Reason, Stacktrace}}
    end.