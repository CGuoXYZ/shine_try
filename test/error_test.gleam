import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gleeunit

import error

pub fn main() -> Nil {
  gleeunit.main()
}

// 用于测试的自定义类型
type Point {
  Point(x: Int, y: Int)
}

// ───────────────────────── 解析 reason 的工具 ─────────────────────────
//
// 新版的 Exception 只给出原始的 reason / stacktrace，
// 所以下面这两个 helper 正是"使用者拿到裸 reason 之后要自己做的事"。

/// reason 是 atom 键的 Erlang map，Gleam 里写不出 atom 键，
/// 所以整体解出来后再用 string.inspect 出来的名字比对
fn entries(reason: Dynamic) -> List(#(String, Dynamic)) {
  case decode.run(reason, decode.dict(decode.dynamic, decode.dynamic)) {
    Error(_) -> []
    Ok(dict) ->
      dict
      |> dict.to_list
      |> list.map(fn(kv) { #(string.inspect(kv.0), kv.1) })
  }
}

/// reason 里有没有这个字段
fn has_field(reason: Dynamic, name: String) -> Bool {
  entries(reason) |> list.any(fn(kv) { kv.0 == name })
}

/// 取 reason 里某个字段的字符串值（取不到返回空串）
fn text_field(reason: Dynamic, name: String) -> String {
  entries(reason)
  |> list.find_map(fn(kv) {
    case kv.0 == name {
      True ->
        case decode.run(kv.1, decode.string) {
          Ok(text) -> Ok(text)
          Error(_) -> Error(Nil)
        }
      False -> Error(Nil)
    }
  })
  |> result.unwrap("")
}

/// class 是原始的 Erlang atom：error / exit / throw。
/// string.inspect 会把它渲染成 "Error" / "Exit" / "Throw"。
fn class_name(class: Dynamic) -> String {
  string.inspect(class)
}

// 测试里需要主动抛出另外两类异常和真实的 Erlang 错误
@external(erlang, "erlang", "throw")
fn throw(value: a) -> b

@external(erlang, "erlang", "exit")
fn exit(reason: a) -> b

@external(erlang, "lists", "nth")
fn nth(list: List(a), n: Int) -> a

@external(erlang, "erlang", "binary_to_integer")
fn binary_to_integer(bits: BitArray) -> Int

// ─────────────────────────── 正常透传 ───────────────────────────

pub fn ok_int_test() {
  assert error.try(fn() { 1 + 9 }) == Ok(10)
}

pub fn ok_nil_test() {
  assert error.try(fn() { Nil }) == Ok(Nil)
}

pub fn ok_string_test() {
  assert error.try(fn() { "hello" }) == Ok("hello")
}

pub fn ok_list_test() {
  assert error.try(fn() { [1, 2, 3] }) == Ok([1, 2, 3])
}

pub fn ok_custom_type_test() {
  assert error.try(fn() { Point(1, 2) }) == Ok(Point(1, 2))
}

/// 返回值本身是 Result 时不会被展平
pub fn ok_nested_result_test() {
  assert error.try(fn() { Ok(1) }) == Ok(Ok(1))
}

// ─────────────────── Gleam 自己的错误（reason 是 map） ───────────────────

/// Gleam 的异常 reason 是一个带 GleamError/Message/File/Line 的 map
pub fn panic_reason_is_map_test() {
  let assert Error(e) = error.try(fn() { panic })

  assert dynamic.classify(e.reason) == "Dict"
  assert has_field(e.reason, "GleamError")
  assert has_field(e.reason, "Message")
  assert has_field(e.reason, "File")
  assert has_field(e.reason, "Line")
}

/// Gleam 异常的 file 来自编译器写死的字面量，精确可靠
pub fn gleam_error_file_test() {
  let assert Error(e) = error.try(fn() { panic })
  assert text_field(e.reason, "File") == "test/error_test.gleam"
}

pub fn panic_message_test() {
  let assert Error(e) = error.try(fn() { panic })
  assert text_field(e.reason, "Message") == "`panic` expression evaluated."
}

pub fn panic_as_message_test() {
  let assert Error(e) = error.try(fn() { panic as "自定义消息" })
  assert text_field(e.reason, "Message") == "自定义消息"
}

pub fn todo_message_test() {
  let assert Error(e) = error.try(fn() { todo as "未完成" })
  assert text_field(e.reason, "Message") == "未完成"
}

pub fn assert_message_test() {
  let a = 1
  let b = 2
  let assert Error(e) =
    error.try(fn() {
      assert a == b as "断言失败"
    })
  assert text_field(e.reason, "Message") == "断言失败"
}

pub fn let_assert_message_test() {
  let assert Error(e) =
    error.try(fn() {
      let assert [_] = [3, 4] as "失败"
    })
  assert text_field(e.reason, "Message") == "失败"
}

// ──────────────────── 原始 Erlang 异常（reason 是裸值） ────────────────────

/// throw 的 reason 就是被抛出的那个值
pub fn throw_reason_test() {
  let assert Error(e) = error.try(fn() { throw("boom") })
  assert dynamic.classify(e.reason) == "String"

  let assert Ok(text) = decode.run(e.reason, decode.string)
  assert text == "boom"
}

/// exit 的 reason 就是退出原因
pub fn exit_reason_test() {
  let assert Error(e) = error.try(fn() { exit(1) })
  assert dynamic.classify(e.reason) == "Int"

  let assert Ok(reason) = decode.run(e.reason, decode.int)
  assert reason == 1
}

/// 真实的 Erlang 运行时错误：function_clause（reason 是 atom）
pub fn function_clause_reason_test() {
  let assert Error(e) = error.try(fn() { nth([], 0) })
  assert dynamic.classify(e.reason) == "Atom"
  assert !has_field(e.reason, "Message")
}

/// 真实的 Erlang 运行时错误：badarg（reason 是 atom）
pub fn badarg_reason_test() {
  let assert Error(e) = error.try(fn() { binary_to_integer(<<"x">>) })
  assert dynamic.classify(e.reason) == "Atom"
}

// ────────────────────── 异常类别（class） ──────────────────────
//
// class 是原始的 Erlang atom，用 string.inspect 得到可读名字。
// 它是 reason / stacktrace 里**拿不到**的信息。

/// Gleam 自己的错误 → error 类
pub fn class_of_gleam_error_test() {
  let assert Error(e) = error.try(fn() { panic })
  assert dynamic.classify(e.class) == "Atom"
  assert class_name(e.class) == "Error"
}

/// 原始 Erlang 运行时错误 → 同样是 error 类
pub fn class_of_erlang_error_test() {
  let assert Error(e) = error.try(fn() { nth([], 0) })
  assert class_name(e.class) == "Error"
}

/// exit → exit 类
pub fn class_of_exit_test() {
  let assert Error(e) = error.try(fn() { exit(1) })
  assert class_name(e.class) == "Exit"
}

/// throw → throw 类
pub fn class_of_throw_test() {
  let assert Error(e) = error.try(fn() { throw("boom") })
  assert class_name(e.class) == "Throw"
}

/// class 能区分 reason 区分不了的东西：
/// throw("same") 和 exit("same") 的 reason 完全一样，只有 class 不同。
pub fn class_distinguishes_what_reason_cannot_test() {
  let assert Error(a) = error.try(fn() { throw("same") })
  let assert Error(b) = error.try(fn() { exit("same") })

  // reason 一模一样
  assert a.reason == b.reason
  assert dynamic.classify(a.reason) == "String"

  // 但 class 分得开
  assert class_name(a.class) == "Throw"
  assert class_name(b.class) == "Exit"
}

// ─────────────────────────── 结构与边界 ───────────────────────────

pub fn stacktrace_not_empty_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })

  assert dynamic.classify(e.stacktrace) == "List"
  let assert Ok(frames) = decode.run(e.stacktrace, decode.list(decode.dynamic))
  assert !list.is_empty(frames)
}

/// 内层 try 捕获后，外层正常返回
pub fn nested_try_inner_test() {
  let result =
    error.try(fn() {
      case error.try(fn() { panic as "inner" }) {
        Ok(_) -> "不该到这里"
        Error(_) -> "内层已捕获"
      }
    })
  assert result == Ok("内层已捕获")
}

/// 内层正常，外层出错 → 外层捕获
pub fn nested_try_outer_test() {
  let result =
    error.try(fn() {
      let _ = error.try(fn() { 1 })
      panic as "outer"
    })
  let assert Error(e) = result
  assert text_field(e.reason, "Message") == "outer"
}

/// 文档里写明的边界：进程崩溃（退出信号）不是异常，try 抓不到。
///
/// 回调里链接一个会崩的进程，退出信号会直接杀死调用方，
/// 所以这个 worker 不应该再有任何消息发出来。
pub fn signal_not_caught_test() {
  let survived = process.new_subject()

  let _ =
    process.spawn_unlinked(fn() {
      let _ =
        error.try(fn() {
          let _ = process.spawn(fn() { panic })
          process.sleep(30)
          1
        })
      // 能走到这里说明 try 抓到了信号（与文档不符）
      process.send(survived, Nil)
    })

  assert process.receive(survived, 300) == Error(Nil)
}
