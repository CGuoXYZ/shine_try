import gleam/dynamic.{type Dynamic}

pub type Exception {
  Exception(class: Dynamic, reason: Dynamic, stacktrace: Dynamic)
}

/// 运行可能产生异常的函数
/// 
/// 会捕获 error/exit/throw 三种异常类型，但对于进程崩溃的异常无法处理
@external(erlang, "error_ffi", "try_func")
pub fn try(func: fn() -> return) -> Result(return, Exception)

/// 无论是否异常都运行清理函数
@external(erlang, "error_ffi", "defer")
pub fn defer(clean: fn() -> discard, body: fn() -> return) -> return

/// 只在发生异常时运行清理函数
@external(erlang, "error_ffi", "on_crash")
pub fn on_crash(clean: fn() -> discard, body: fn() -> return) -> return
