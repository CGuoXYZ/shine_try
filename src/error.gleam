import gleam/dynamic.{type Dynamic}
import gleam/result

pub type Exception {
  Exception(class: Dynamic, reason: Dynamic, stacktrace: Dynamic)
}

/// 运行可能产生异常的函数
/// 
/// 会捕获 error/exit/throw 三种异常类型，但对于进程崩溃的异常无法处理
pub fn try(func: fn() -> return) -> Result(return, Exception) {
  // 运行给定的函数并试图捕获异常
  // 没有异常直接返回其值，否则返回Exception
  use #(class, reason, stacktrace) <- result.try_recover(try_func(func))
  Exception(class:, reason:, stacktrace:) |> Error()
}

@external(erlang, "error_ffi", "try_func")
fn try_func(func: fn() -> val) -> Result(val, #(Dynamic, Dynamic, Dynamic))

/// 无论是否异常都运行清理函数
@external(erlang, "error_ffi", "defer_func")
pub fn defer(clean: fn() -> discard, body: fn() -> return) -> return

/// 只在发生异常时运行清理函数
@external(erlang, "error_ffi", "on_crash_func")
pub fn on_crash(clean: fn() -> discard, body: fn() -> return) -> return
