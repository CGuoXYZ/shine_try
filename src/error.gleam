import gleam/dynamic.{type Dynamic}
import gleam/result

pub type Exception {
  Exception(class: Dynamic, reason: Dynamic, stacktrace: Dynamic)
}

/// 运行可能产生异常的函数
/// 
/// 会捕获 error/exit/throw 三种异常类型，但对于进程崩溃的异常无法处理
pub fn try(func: fn() -> val) -> Result(val, Exception) {
  // 运行给定的函数并试图捕获异常
  // 没有异常直接返回其值，否则返回Exception
  use #(class, reason, stacktrace) <- result.try_recover(try_func(func))
  Exception(class:, reason:, stacktrace:) |> Error()
}

@external(erlang, "error_ffi", "try_func")
fn try_func(func: fn() -> val) -> Result(val, #(Dynamic, Dynamic, Dynamic))
