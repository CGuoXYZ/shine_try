import gleam/dynamic.{type Dynamic}
import gleam/result

import stacktrace.{type StackFrameList}

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

/// 无论是否异常都运行清理函数
pub fn defer(clean: fn() -> discard, body: fn() -> return) -> return {
  defer_func(clean, body)
}

/// 只在发生异常时运行清理函数
pub fn on_crash(clean: fn() -> discard, body: fn() -> return) -> return {
  on_crash_func(clean, body)
}

/// 从Exception获取栈帧列表
pub fn stacktrace_from_exception(exception: Exception) -> StackFrameList {
  stacktrace.from_dynamic(exception.stacktrace)
}

@external(erlang, "error_ffi", "defer_func")
fn defer_func(clean: fn() -> discard, body: fn() -> return) -> return

@external(erlang, "error_ffi", "on_crash_func")
fn on_crash_func(clean: fn() -> discard, body: fn() -> return) -> return

@external(erlang, "error_ffi", "try_func")
fn try_func(func: fn() -> val) -> Result(val, #(Dynamic, Dynamic, Dynamic))
