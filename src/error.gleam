import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const gleam_error = "GleamError"

const message = "Message"

const file = "File"

const line = "Line"

/// 异常的基础信息：
/// 
/// class：异常类型
/// 
/// is_gleam_error：是否为gleam异常
/// 
/// message：异常附带的消息(如果是gleam异常)
/// 
/// file：异常产生的文件(如果是gleam异常)
/// 
/// line：异常产生的行号(如果是gleam异常)
/// 
/// reason：原始的Reason，可自行解析
/// 
/// stacktrace：原始的Stackrace，可自行解析
pub type Exception {
  Exception(
    class: Class,
    is_gleam_error: Bool,
    message: Option(String),
    file: Option(String),
    line: Option(Int),
    reason: Dynamic,
    stacktrace: Dynamic,
  )
}

/// 异常类型
pub type Class {
  ErrorClass
  ExitClass
  ThrowClass
}

/// 运行可能产生异常的函数
/// 
/// 会捕获 error/exit/throw 三种异常类型，但对于进程崩溃的异常无法处理
pub fn try(func: fn() -> val) -> Result(val, Exception) {
  // 运行给定的函数并试图捕获异常
  // 没有异常直接返回其值，否则返回Exception
  use #(class, reason, stacktrace) <- result.try_recover(try_func(func))
  // 从reason获取字典
  let dict = dict_of(reason)
  // 检查字典是否有"GleamError"键判断是否为gleam异常
  let is_gleam_error = is_gleam_error(dict)

  Exception(
    // 异常类型
    class: class_of(class),
    // 是否为gleam异常
    is_gleam_error:,
    // 异常消息(若有)
    message: message_of(dict, is_gleam_error),
    // 异常产生的文件(若有)
    file: file_of(dict, is_gleam_error),
    // 异常产生的行号(若有)
    line: line_of(dict, is_gleam_error),
    // 原始的Reason
    reason:,
    // 原始的Stacktrace
    stacktrace:,
  )
  |> Error()
}

/// 从原始的Reason获取字典
fn dict_of(dyn: Dynamic) -> Dict(String, Dynamic) {
  case decode.run(dyn, decode.dict(decode.dynamic, decode.dynamic)) {
    Error(_) -> dict.new()
    Ok(dict) ->
      dict
      |> dict.to_list()
      |> list.map(fn(kv) { #(string.inspect(kv.0), kv.1) })
      |> dict.from_list()
  }
}

/// 从字典获取指定键的动态值，若没有则返回Nil的动态值
fn dynamic_of(dict: Dict(String, Dynamic), key: String) -> Dynamic {
  result.unwrap(dict.get(dict, key), dynamic.nil())
}

/// 从字典获取字符串
fn str_of(dict: Dict(String, Dynamic), key: String) -> String {
  dynamic_of(dict, key)
  |> decode.run(decode.string)
  |> result.unwrap("")
}

/// 从字典获取整数
fn int_of(dict: Dict(String, Dynamic), key: String) -> Int {
  dynamic_of(dict, key)
  |> decode.run(decode.int)
  |> result.unwrap(0)
}

/// 获取异常的类型
fn class_of(class: Dynamic) -> Class {
  case string.inspect(class) {
    "Throw" -> ThrowClass
    "Exit" -> ExitClass
    _ -> ErrorClass
  }
}

/// 检查字典中是否有特定键键来判断是否为gleam异常
fn is_gleam_error(dict: Dict(String, Dynamic)) -> Bool {
  dict.has_key(dict, gleam_error)
}

/// 从字典获取异常附带的消息
fn message_of(
  dict: Dict(String, Dynamic),
  is_gleam_error: Bool,
) -> Option(String) {
  use <- bool.guard(!is_gleam_error, None)
  str_of(dict, message) |> Some()
}

/// 从字典获取异常产生的文件
fn file_of(
  dict: Dict(String, Dynamic),
  is_gleam_error: Bool,
) -> Option(String) {
  use <- bool.guard(!is_gleam_error, None)
  str_of(dict, file) |> Some()
}

/// 从字典获取异常产生的行号
fn line_of(dict: Dict(String, Dynamic), is_gleam_error: Bool) -> Option(Int) {
  use <- bool.guard(!is_gleam_error, None)
  int_of(dict, line) |> Some()
}

@external(erlang, "error_ffi", "try_func")
fn try_func(func: fn() -> val) -> Result(val, #(Dynamic, Dynamic, Dynamic))
