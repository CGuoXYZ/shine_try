import error
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string

// ─────────────────────── 测试用的外部异常 ───────────────────────

@external(erlang, "erlang", "throw")
fn throw(value: a) -> b

@external(erlang, "erlang", "exit")
fn exit(reason: a) -> b

// ─────────────────────── reason / class 解析 ───────────────────────
//
// Exception.reason 是裸 Dynamic（Gleam 异常的 reason 是 atom 键的 map），
// 这里用的是和 error_test 一样的手法。

fn reason_entries(reason: Dynamic) -> List(#(String, Dynamic)) {
  case decode.run(reason, decode.dict(decode.dynamic, decode.dynamic)) {
    Error(_) -> []
    Ok(dict) ->
      dict
      |> dict.to_list
      |> list.map(fn(kv) { #(string.inspect(kv.0), kv.1) })
  }
}

fn reason_message(e: error.Exception) -> String {
  reason_entries(e.reason)
  |> list.find_map(fn(kv) {
    case kv.0 == "Message" {
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

fn class_name(e: error.Exception) -> String {
  string.inspect(e.class)
}

// ─────────────────── 用 Subject 记录执行顺序 ───────────────────
//
// clean 和 body 都在同一个进程里同步执行，
// 所以往同一个 subject 发消息就能精确还原调用顺序。

fn note(subject: process.Subject(String), text: String) -> Nil {
  process.send(subject, text)
}

fn next(subject: process.Subject(String)) -> Result(String, Nil) {
  process.receive(subject, 100)
}

/// 等一条消息，取不到就返回空串（断言失败时能看到实际值）
fn take(subject: process.Subject(String)) -> String {
  case next(subject) {
    Ok(text) -> text
    Error(_) -> "<没有消息>"
  }
}

// ═════════════════════════════ defer ═════════════════════════════

/// body 先跑，clean 后跑
pub fn defer_runs_body_then_clean_test() {
  let subject = process.new_subject()

  let value =
    error.defer(fn() { note(subject, "clean") }, fn() {
      note(subject, "body")
      42
    })

  assert value == 42
  assert take(subject) == "body"
  assert take(subject) == "clean"
}

/// defer 不包 Result，直接返回 body 的值
pub fn defer_returns_body_value_raw_test() {
  assert error.defer(fn() { Nil }, fn() { "hello" }) == "hello"
  assert error.defer(fn() { Nil }, fn() { [1, 2, 3] }) == [1, 2, 3]
}

/// clean 的返回值被丢弃，不影响 defer 的返回值
pub fn defer_clean_return_value_ignored_test() {
  assert error.defer(fn() { "clean result" }, fn() { 42 }) == 42
}

/// body 抛异常时 clean 依然执行，异常继续往上传播
pub fn defer_clean_runs_when_body_raises_test() {
  let subject = process.new_subject()

  let assert Error(e) =
    error.try(fn() {
      error.defer(fn() { note(subject, "clean") }, fn() {
        note(subject, "body")
        panic as "body_error"
      })
    })

  assert reason_message(e) == "body_error"
  assert take(subject) == "body"
  assert take(subject) == "clean"
}

/// body 正常返回、clean 抛异常 → 异常传播出去
pub fn defer_clean_exception_on_success_path_test() {
  let assert Error(e) =
    error.try(fn() { error.defer(fn() { panic as "clean_error" }, fn() { 42 }) })

  assert reason_message(e) == "clean_error"
}

/// 当前语义（Erlang try/after）：clean 抛出的异常会取代 body 的原始异常。
///
/// 这是有意锁住当前行为的测试。如果以后决定改成"保留原始异常"，
/// 这个测试和 on_crash 的那条都要跟着改。
pub fn defer_clean_exception_wins_over_body_test() {
  let assert Error(e) =
    error.try(fn() {
      error.defer(fn() { panic as "clean_error" }, fn() { panic as "body_error" })
    })

  assert reason_message(e) == "clean_error"
}

/// 嵌套时由内向外依次清理
pub fn defer_nested_order_test() {
  let subject = process.new_subject()

  let _value =
    error.defer(fn() { note(subject, "outer_clean") }, fn() {
      error.defer(fn() { note(subject, "inner_clean") }, fn() {
        note(subject, "body")
        1
      })
    })

  assert take(subject) == "body"
  assert take(subject) == "inner_clean"
  assert take(subject) == "outer_clean"
}

/// use 语法
pub fn defer_use_syntax_test() {
  let subject = process.new_subject()

  assert with_defer(subject) == 7
  assert take(subject) == "body"
  assert take(subject) == "clean"
}

fn with_defer(subject: process.Subject(String)) -> Int {
  use <- error.defer(fn() { note(subject, "clean") })
  note(subject, "body")
  7
}

/// exit / throw 也照样清理
pub fn defer_clean_runs_for_all_classes_test() {
  let subject = process.new_subject()
  let assert Error(_) =
    error.try(fn() {
      error.defer(fn() { note(subject, "c1") }, fn() { throw("t") })
    })
  assert take(subject) == "c1"

  let assert Error(_) =
    error.try(fn() {
      error.defer(fn() { note(subject, "c2") }, fn() { exit(1) })
    })
  assert take(subject) == "c2"
}

// ═══════════════════════════ on_crash ═══════════════════════════

/// 正常返回时 clean 不执行
pub fn on_crash_clean_skipped_on_success_test() {
  let subject = process.new_subject()

  let value =
    error.on_crash(fn() { note(subject, "clean") }, fn() {
      note(subject, "body")
      7
    })

  assert value == 7

  // 哨兵消息：如果 clean 真的发了消息，一定排在哨兵前面
  note(subject, "sentinel")
  assert take(subject) == "body"
  assert take(subject) == "sentinel"
}

/// 抛异常时 clean 执行
pub fn on_crash_clean_runs_on_exception_test() {
  let subject = process.new_subject()

  let assert Error(e) =
    error.try(fn() {
      error.on_crash(fn() { note(subject, "clean") }, fn() {
        note(subject, "body")
        panic as "body_error"
      })
    })

  assert reason_message(e) == "body_error"
  assert take(subject) == "body"
  assert take(subject) == "clean"
}

/// on_crash 会把原始异常原样抛出去
pub fn on_crash_preserves_original_exception_test() {
  let assert Error(e) =
    error.try(fn() {
      error.on_crash(fn() { Nil }, fn() { panic as "body_error" })
    })

  assert reason_message(e) == "body_error"
  assert class_name(e) == "Error"
}

/// 当前语义：clean 抛出的异常取代原始异常
pub fn on_crash_clean_exception_wins_over_body_test() {
  let assert Error(e) =
    error.try(fn() {
      error.on_crash(fn() { panic as "clean_error" }, fn() {
        panic as "body_error"
      })
    })

  assert reason_message(e) == "clean_error"
}

/// use 语法
pub fn on_crash_use_syntax_test() {
  let subject = process.new_subject()

  let assert Error(e) = with_on_crash(subject)
  assert reason_message(e) == "boom"
  assert take(subject) == "body"
  assert take(subject) == "clean"
}

fn with_on_crash(
  subject: process.Subject(String),
) -> Result(Int, error.Exception) {
  error.try(fn() {
    use <- error.on_crash(fn() { note(subject, "clean") })
    note(subject, "body")
    panic as "boom"
  })
}

/// exit / throw 也会触发清理，并原样传出去
pub fn on_crash_clean_runs_for_all_classes_test() {
  let subject = process.new_subject()

  let assert Error(e1) =
    error.try(fn() {
      error.on_crash(fn() { note(subject, "c1") }, fn() { throw("t") })
    })
  assert class_name(e1) == "Throw"
  assert take(subject) == "c1"

  let assert Error(e2) =
    error.try(fn() {
      error.on_crash(fn() { note(subject, "c2") }, fn() { exit(1) })
    })
  assert class_name(e2) == "Exit"
  assert take(subject) == "c2"
}

// ═══════════════════════ defer / on_crash 对比 ═══════════════════════

/// 唯一的区别：成功路径上 defer 会清理，on_crash 不会
pub fn defer_and_on_crash_differ_only_on_success_test() {
  let defer_subject = process.new_subject()
  let crash_subject = process.new_subject()

  let _ = error.defer(fn() { note(defer_subject, "clean") }, fn() { 1 })
  let _ = error.on_crash(fn() { note(crash_subject, "clean") }, fn() { 1 })

  note(defer_subject, "sentinel")
  note(crash_subject, "sentinel")

  assert take(defer_subject) == "clean"
  assert take(crash_subject) == "sentinel"
}

/// 三类异常都能穿过 defer 和 on_crash
pub fn all_classes_pass_through_test() {
  let assert Error(e1) =
    error.try(fn() { error.defer(fn() { Nil }, fn() { panic as "e" }) })
  assert class_name(e1) == "Error"

  let assert Error(e2) =
    error.try(fn() { error.defer(fn() { Nil }, fn() { throw("t") }) })
  assert class_name(e2) == "Throw"

  let assert Error(e3) =
    error.try(fn() { error.defer(fn() { Nil }, fn() { exit(1) }) })
  assert class_name(e3) == "Exit"

  let assert Error(e4) =
    error.try(fn() { error.on_crash(fn() { Nil }, fn() { panic as "e" }) })
  assert class_name(e4) == "Error"

  let assert Error(e5) =
    error.try(fn() { error.on_crash(fn() { Nil }, fn() { throw("t") }) })
  assert class_name(e5) == "Throw"

  let assert Error(e6) =
    error.try(fn() { error.on_crash(fn() { Nil }, fn() { exit(1) }) })
  assert class_name(e6) == "Exit"
}
