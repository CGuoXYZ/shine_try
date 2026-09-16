import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}

import error

// 用于测试的自定义类型
type Point {
  Point(x: Int, y: Int)
}

// ───────────────────────────── 工具 ─────────────────────────────

/// 断言：这是 Gleam 自己抛出的错误（信息齐全）
fn assert_gleam_error(result: Result(a, error.Exception)) -> error.Exception {
  let assert Error(e) = result
  assert e.is_gleam_error == True
  assert e.message != None
  assert e.file != None
  assert e.line != None
  e
}

/// 断言：这不是 Gleam 错误，而是原始 Erlang 异常（没有可解析的信息）
fn assert_erlang_error(result: Result(a, error.Exception)) -> error.Exception {
  let assert Error(e) = result
  assert e.is_gleam_error == False
  assert e.message == None
  assert e.file == None
  assert e.line == None
  e
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

// ─────────────────────── Gleam 自己的错误 ───────────────────────

pub fn panic_test() {
  let e = assert_gleam_error(error.try(fn() { panic }))
  assert e.class == error.ErrorClass
  assert e.message == Some("`panic` expression evaluated.")
}

pub fn panic_as_test() {
  let e = assert_gleam_error(error.try(fn() { panic as "自定义消息" }))
  assert e.class == error.ErrorClass
  assert e.message == Some("自定义消息")
}

pub fn todo_test() {
  let e = assert_gleam_error(error.try(fn() { todo }))
  assert e.class == error.ErrorClass
  let assert Some(_) = e.message
}

pub fn todo_as_test() {
  let e = assert_gleam_error(error.try(fn() { todo as "未完成" }))
  assert e.class == error.ErrorClass
  assert e.message == Some("未完成")
}

pub fn assert_test() {
  let a = 1
  let b = 2
  let e =
    assert_gleam_error(
      error.try(fn() {
        assert a == b
      }),
    )
  assert e.class == error.ErrorClass
  assert e.message == Some("Assertion failed.")
}

pub fn assert_as_test() {
  let a = 1
  let b = 2
  let e =
    assert_gleam_error(
      error.try(fn() {
        assert a == b as "断言失败"
      }),
    )
  assert e.message == Some("断言失败")
}

pub fn let_assert_test() {
  let e =
    assert_gleam_error(
      error.try(fn() {
        let assert [_] = [3, 4]
      }),
    )
  assert e.class == error.ErrorClass
  let assert Some(_) = e.message
}

pub fn let_assert_as_test() {
  let e =
    assert_gleam_error(
      error.try(fn() {
        let assert [_] = [3, 4] as "失败"
      }),
    )
  assert e.message == Some("失败")
}

/// Gleam 错误的 file / line 来自编译器写死的字面量，精确可靠
pub fn gleam_error_location_test() {
  let e = assert_gleam_error(error.try(fn() { panic as "x" }))
  assert e.file == Some("test/error_test.gleam")
  let assert Some(line) = e.line
  assert line > 0
}

/// Gleam 错误的 reason 是带 gleam_error 键的 map
pub fn gleam_error_reason_is_map_test() {
  let e = assert_gleam_error(error.try(fn() { panic }))
  assert dynamic.classify(e.reason) == "Dict"
}

// ──────────────────── 原始 Erlang 异常（三类） ────────────────────

pub fn throw_test() {
  let e = assert_erlang_error(error.try(fn() { throw("boom") }))
  assert e.class == error.ThrowClass
}

/// throw 的 reason 就是被抛出的那个值
pub fn throw_reason_test() {
  let e = assert_erlang_error(error.try(fn() { throw("boom") }))
  assert dynamic.classify(e.reason) == "String"
}

pub fn exit_test() {
  let e = assert_erlang_error(error.try(fn() { exit(1) }))
  assert e.class == error.ExitClass
}

pub fn exit_string_test() {
  let e = assert_erlang_error(error.try(fn() { exit("bye") }))
  assert e.class == error.ExitClass
}

/// 真实的 Erlang 运行时错误：function_clause
pub fn erlang_function_clause_test() {
  let e = assert_erlang_error(error.try(fn() { nth([], 0) }))
  assert e.class == error.ErrorClass
}

/// 运行时错误的 reason 是 atom，用户依然能拿到
pub fn erlang_reason_atom_test() {
  let e = assert_erlang_error(error.try(fn() { nth([], 0) }))
  assert dynamic.classify(e.reason) == "Atom"
}

/// 真实的 Erlang 运行时错误：badarg
pub fn erlang_badarg_test() {
  let e = assert_erlang_error(error.try(fn() { binary_to_integer(<<"x">>) }))
  assert e.class == error.ErrorClass
}

/// 三类异常靠 class 区分
pub fn class_distinguishes_three_test() {
  let assert Error(a) = error.try(fn() { panic })
  let assert Error(b) = error.try(fn() { exit(1) })
  let assert Error(c) = error.try(fn() { throw(1) })
  assert a.class == error.ErrorClass
  assert b.class == error.ExitClass
  assert c.class == error.ThrowClass
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
  assert e.is_gleam_error == True
  assert e.message == Some("outer")
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
