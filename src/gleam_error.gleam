import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

import error.{type Exception}

const function_ = "function"

const line_ = "line"

const message_ = "message"

const module_ = "module"

const file_ = "file"

const gleam_error_ = "gleam_error"

const left_ = "left"

const right_ = "right"

const expression_ = "expression"

const value_ = "value"

const operator_ = "operator"

const arguments_ = "arguments"

/// 异常共同携带的信息
pub type BasicInfo {
  /// module：异常的模块
  /// 
  /// file：异常的文件
  /// 
  /// function：异常的函数
  /// 
  /// line：异常的行号(准确)
  /// 
  /// message：异常附带的消息
  BasicInfo(
    module: String,
    file: String,
    function: String,
    line: Int,
    message: String,
  )
}

/// gleam异常`panic`/`todo`/`assert`/`let assert`
pub type GleamError {
  /// `panic` 引发的异常
  Panic(basic: BasicInfo)

  /// `todo` 引发的异常
  Todo(basic: BasicInfo)

  /// `assert`的`assert val`格式 引发的异常
  /// 
  /// value：断言失败的值
  AssertSingle(basic: BasicInfo, value: Dynamic)
  /// `assert`的`assert func()`格式 引发的异常
  /// 
  /// arguments：断言失败的函数的参数列表
  AssertFuncCall(basic: BasicInfo, arguments: List(Dynamic))
  /// `assert`的`assert val1 == val2`或`assert func() == func()`格式 引发的异常
  /// 
  /// left_value：左侧表达是的值
  /// 
  /// right_value：右侧表达式的值
  /// 
  /// operator：运算符
  AssertPair(
    basic: BasicInfo,
    left_value: Dynamic,
    right_value: Dynamic,
    operator: String,
  )

  /// `let assert` 引发的异常
  /// 
  /// value：匹配失败的值
  LetAssert(basic: BasicInfo, value: Dynamic)
}

type Reason =
  Dict(Atom, Dynamic)

/// 从Exception获取GleamError
/// 
/// 由于类型是公开的，你完全可以伪造一个Reason
pub fn from_exception(ex: Exception) -> Result(GleamError, Nil) {
  case decode.run(ex.reason, decode.dict(atom.decoder(), decode.dynamic)) {
    Error(_) -> Error(Nil)
    Ok(reason) -> Ok(reason)
  }
  |> result.try(gleam_error)
}

/// 获取异常产生的函数
fn function(rsn: Reason) -> Option(String) {
  decode_reason(rsn, function_, decode.string)
}

/// 获取异常产生的行号
fn line(rsn: Reason) -> Option(Int) {
  decode_reason(rsn, line_, decode.int)
}

/// 获取异常附带的消息
fn message(rsn: Reason) -> Option(String) {
  decode_reason(rsn, message_, decode.string)
}

/// 获取异常产生的模块
fn module(rsn: Reason) -> Option(String) {
  decode_reason(rsn, module_, decode.string)
}

/// 获取异常产生的文件
fn file(rsn: Reason) -> Option(String) {
  decode_reason(rsn, file_, decode.string)
}

/// 获取左侧表达式
fn left(rsn: Reason) -> Option(Reason) {
  decode_reason(rsn, left_, decode.dict(atom.decoder(), decode.dynamic))
}

/// 获取右侧表达式
fn right(rsn: Reason) -> Option(Reason) {
  decode_reason(rsn, right_, decode.dict(atom.decoder(), decode.dynamic))
}

/// 获取表达式
fn expression(rsn: Reason) -> Option(Reason) {
  decode_reason(rsn, expression_, decode.dict(atom.decoder(), decode.dynamic))
}

/// 获取表达式的值
fn expression_value(rsn: Reason) -> Option(Dynamic) {
  use expression <- option.then(expression(rsn))
  value(expression)
}

/// 获取值
fn value(rsn: Reason) -> Option(Dynamic) {
  decode_reason(rsn, value_, decode.dynamic)
}

/// 获取左侧表达式的值
fn left_value(rsn: Reason) -> Option(Dynamic) {
  use left <- option.then(left(rsn))
  value(left)
}

/// 获取右侧表达式的值
fn right_value(rsn: Reason) -> Option(Dynamic) {
  use right <- option.then(right(rsn))
  value(right)
}

/// 获取运算符
fn operator(rsn: Reason) -> Option(String) {
  use operator <- option.then(decode_reason(rsn, operator_, atom.decoder()))
  atom.to_string(operator)
  |> Some()
}

/// 获取导致断言失败的函数的参数列表(倒序)
fn arguments(rsn: Reason) -> Option(List(Dynamic)) {
  use arguments <- option.then(decode_reason(
    rsn,
    arguments_,
    decode.list(decode.dict(atom.decoder(), decode.dynamic)),
  ))
  list.try_map(arguments, fn(rsn) { value(rsn) |> option.to_result(Nil) })
  |> option.from_result()
}

/// 获取异常类型
fn gleam_error(rsn: Reason) -> Result(GleamError, Nil) {
  {
    use gleam_error <- option.then(decode_reason(
      rsn,
      gleam_error_,
      atom.decoder(),
    ))
    case atom.to_string(gleam_error) {
      "panic" -> panic_err(rsn)
      "todo" -> todo_err(rsn)
      "assert" -> assert_err(rsn)
      "let_assert" -> let_assert_err(rsn)
      _ -> None
    }
  }
  |> option.to_result(Nil)
}

fn err_basic_info(rsn: Reason) -> Option(BasicInfo) {
  use module <- option.then(module(rsn))
  use file <- option.then(file(rsn))
  use function <- option.then(function(rsn))
  use line <- option.then(line(rsn))
  use message <- option.then(message(rsn))
  BasicInfo(module:, file:, function:, line:, message:)
  |> Some()
}

fn panic_err(rsn: Reason) -> Option(GleamError) {
  use basic <- option.then(err_basic_info(rsn))
  Panic(basic:)
  |> Some()
}

fn todo_err(rsn: Reason) -> Option(GleamError) {
  use basic <- option.then(err_basic_info(rsn))
  Todo(basic:)
  |> Some()
}

fn assert_err(rsn: Reason) -> Option(GleamError) {
  use basic <- option.then(err_basic_info(rsn))
  case expression_value(rsn) {
    Some(value) ->
      AssertSingle(basic:, value:)
      |> Some()
    None ->
      case arguments(rsn) {
        Some(arguments) ->
          AssertFuncCall(basic:, arguments:)
          |> Some()
        None -> {
          use left_value <- option.then(left_value(rsn))
          use right_value <- option.then(right_value(rsn))
          use operator <- option.then(operator(rsn))
          AssertPair(basic:, left_value:, right_value:, operator:)
          |> Some()
        }
      }
  }
}

fn let_assert_err(rsn: Reason) -> Option(GleamError) {
  use basic <- option.then(err_basic_info(rsn))
  use value <- option.then(value(rsn))
  LetAssert(basic:, value:)
  |> Some()
}

fn decode_reason(
  rsn: Reason,
  key: String,
  decoder: Decoder(return),
) -> Option(return) {
  case dict.get(rsn, atom.create(key)) {
    Error(_) -> None
    Ok(dyn) ->
      case decode.run(dyn, decoder) {
        Error(_) -> None
        Ok(val) -> Some(val)
      }
  }
}
