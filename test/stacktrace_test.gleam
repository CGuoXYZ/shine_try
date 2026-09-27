import error
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import stacktrace

// ───────────────────────── 测试用的外部函数 ─────────────────────────

/// 制造一个真实的 Erlang 运行时错误（badarg），它的栈帧长得很特别
@external(erlang, "erlang", "binary_to_integer")
fn binary_to_integer(bits: BitArray) -> Int

/// stacktrace 里的 file 是 Erlang charlist（一串码点）。
/// 这里用 OTP 自己的函数构造，保证和真实帧里的形状一致。
@external(erlang, "unicode", "characters_to_list")
fn utf_charlist(text: String) -> List(Int)

/// 抛出 throw 类异常（栈帧正常，但 reason 不是 map）
@external(erlang, "erlang", "throw")
fn throw(value: a) -> b

// ─────────────────────── 构造输入 ───────────────────────

/// 用一个动态的栈帧列表伪造 Exception
///
/// Exception 的字段是公开的，而且 from_exception 只读 stacktrace，
/// 所以这样能精确制造真实异常里很难出现的形状（缺字段、顺序颠倒、垃圾帧……）。
fn fake_exception(stacktrace: Dynamic) -> error.Exception {
  error.Exception(class: dynamic.nil(), reason: dynamic.nil(), stacktrace:)
}

// 真实的帧是 Erlang 4 元组 {Module, Function, ArityOrArgs, Location}，
// Location 是 proplist [{file, Charlist}, {line, Int}]。
// Gleam 的 decode.list 对元组也成立，所以用 List 构造等价结构。

fn location_entry(key: String, value: Dynamic) -> Dynamic {
  dynamic.list([atom.to_dynamic(atom.create(key)), value])
}

fn charlist(text: String) -> Dynamic {
  dynamic.list(list.map(utf_charlist(text), dynamic.int))
}

fn frame(
  module_name: String,
  function_name: String,
  third: Dynamic,
  location: List(Dynamic),
) -> Dynamic {
  dynamic.list([
    atom.to_dynamic(atom.create(module_name)),
    atom.to_dynamic(atom.create(function_name)),
    third,
    dynamic.list(location),
  ])
}

/// 一个「正常」的帧：arity 是整数，location 有 file 和 line
fn normal_frame() -> Dynamic {
  frame("good_mod", "good_fun", dynamic.int(0), [
    location_entry("file", charlist("src/good.gleam")),
    location_entry("line", dynamic.int(10)),
  ])
}

/// 只解一个帧，解不出来就让测试失败
fn parse_one(frame: Dynamic) -> stacktrace.StackFrame {
  let assert Ok([only]) =
    stacktrace.from_exception(fake_exception(dynamic.list([frame])))
  only
}

fn index_of_module(
  frames: List(stacktrace.StackFrame),
  module_name: String,
) -> Result(Int, Nil) {
  frames
  |> list.index_map(fn(f, i) { #(f, i) })
  |> list.find_map(fn(pair) {
    case pair.0.module == module_name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}

fn find_frame(
  frames: List(stacktrace.StackFrame),
  module_name: String,
  function_name: String,
) -> Result(stacktrace.StackFrame, Nil) {
  list.find(frames, fn(f) {
    f.module == module_name && f.function == function_name
  })
}

// ─────────────────────── from_exception 的输入边界 ───────────────────────

/// stacktrace 不是列表 → Error(Nil)
pub fn from_exception_non_list_test() {
  assert stacktrace.from_exception(fake_exception(dynamic.nil())) == Error(Nil)
  assert stacktrace.from_exception(fake_exception(dynamic.int(1))) == Error(Nil)
  assert stacktrace.from_exception(fake_exception(dynamic.string("nope")))
    == Error(Nil)
}

/// 空列表是合法的：没有帧，但不是错误
pub fn from_exception_empty_list_test() {
  assert stacktrace.from_exception(fake_exception(dynamic.list([]))) == Ok([])
}

/// 只要有一个帧解不出来，整条解析就失败
///
/// 这是当前 try_map 的语义。如果以后改成「跳过坏帧、能解多少给多少」
/// （filter_map），这条测试要改成断言剩下那个正常帧。
pub fn one_bad_frame_fails_the_whole_parse_test() {
  let input =
    dynamic.list([
      dynamic.int(1),
      normal_frame(),
    ])

  assert stacktrace.from_exception(fake_exception(input)) == Error(Nil)
}

/// 形状不对的帧：不是列表、元素个数不对
pub fn malformed_frames_test() {
  assert stacktrace.from_exception(
      fake_exception(dynamic.list([dynamic.int(1)])),
    )
    == Error(Nil)

  // 5 个元素，不是 4 元组
  let five =
    dynamic.list([
      dynamic.int(1),
      dynamic.int(2),
      dynamic.int(3),
      dynamic.int(4),
      dynamic.int(5),
    ])
  assert stacktrace.from_exception(fake_exception(dynamic.list([five])))
    == Error(Nil)
}

// ───────────────────── 第三位：arity 还是参数列表 ─────────────────────

pub fn arity_is_number_test() {
  assert parse_one(frame("m", "f", dynamic.int(3), [])).params
    == stacktrace.Arity(3)
}

pub fn arity_is_args_test() {
  let parsed =
    parse_one(frame("m", "f", dynamic.list([dynamic.string("x")]), []))
  assert parsed.params == stacktrace.Args([dynamic.string("x")])
}

/// 空参数列表也要走 Args，而不是掉进 Arity
pub fn arity_is_empty_args_test() {
  assert parse_one(frame("m", "f", dynamic.list([]), [])).params
    == stacktrace.Args([])
}

// ─────────────────────── location：按 key 找 ───────────────────────

pub fn location_file_and_line_test() {
  let parsed =
    parse_one(
      frame("m", "f", dynamic.int(0), [
        location_entry("file", charlist("src/a.gleam")),
        location_entry("line", dynamic.int(42)),
      ]),
    )
  assert parsed.location == stacktrace.Location(Some("src/a.gleam"), Some(42))
}

/// line 在前、file 在后也要能解出来（不能写死下标）
pub fn location_order_independent_test() {
  let parsed =
    parse_one(
      frame("m", "f", dynamic.int(0), [
        location_entry("line", dynamic.int(7)),
        location_entry("file", charlist("src/b.gleam")),
      ]),
    )
  assert parsed.location == stacktrace.Location(Some("src/b.gleam"), Some(7))
}

pub fn location_missing_line_test() {
  let parsed =
    parse_one(
      frame("m", "f", dynamic.int(0), [
        location_entry("file", charlist("src/c.gleam")),
      ]),
    )
  assert parsed.location == stacktrace.Location(Some("src/c.gleam"), None)
}

pub fn location_missing_file_test() {
  let parsed =
    parse_one(
      frame("m", "f", dynamic.int(0), [location_entry("line", dynamic.int(9))]),
    )
  assert parsed.location == stacktrace.Location(None, Some(9))
}

/// BIF / stdlib 抛的帧，location 里只有 error_info，没有 file/line
pub fn location_only_unknown_key_test() {
  let parsed =
    parse_one(
      frame("m", "f", dynamic.int(0), [
        location_entry("error_info", dynamic.string("whatever")),
      ]),
    )
  assert parsed.location == stacktrace.Location(None, None)
}

pub fn location_empty_test() {
  assert parse_one(frame("m", "f", dynamic.int(0), [])).location
    == stacktrace.Location(None, None)
}

/// 多出来的未知 key 不影响 file/line 的解析
pub fn location_extra_key_ignored_test() {
  let parsed =
    parse_one(
      frame("m", "f", dynamic.int(0), [
        location_entry("error_info", dynamic.string("whatever")),
        location_entry("file", charlist("src/d.gleam")),
        location_entry("line", dynamic.int(1)),
      ]),
    )
  assert parsed.location == stacktrace.Location(Some("src/d.gleam"), Some(1))
}

/// 非 ASCII 文件名：charlist 里是多字节码点，要按码点还原
pub fn location_non_ascii_file_test() {
  let parsed =
    parse_one(
      frame("m", "f", dynamic.int(0), [
        location_entry("file", charlist("测试/文件.gleam")),
        location_entry("line", dynamic.int(1)),
      ]),
    )
  assert parsed.location == stacktrace.Location(Some("测试/文件.gleam"), Some(1))
}

/// file 不是 charlist 时给 None，而不是炸掉
pub fn location_weird_file_test() {
  let parsed =
    parse_one(
      frame("m", "f", dynamic.int(0), [location_entry("file", dynamic.int(123))]),
    )
  assert parsed.location == stacktrace.Location(None, None)
}

// ──────────────────────────── 真实异常 ────────────────────────────

/// 第一帧就是抛出点：本测试模块里的匿名函数
pub fn real_panic_first_frame_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  let assert Ok(frames) = stacktrace.from_exception(e)
  let assert Ok(first) = list.first(frames)

  assert first.module == "stacktrace_test"
  assert string.contains(first.function, "anonymous")
}

/// 顺序：抛出点在最前面，error.try 在更外层
pub fn real_panic_frame_order_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  let assert Ok(frames) = stacktrace.from_exception(e)

  let assert Ok(inner) = index_of_module(frames, "stacktrace_test")
  let assert Ok(try_index) = index_of_module(frames, "error")

  assert inner == 0
  assert inner < try_index
}

/// 来自 .gleam 源码的帧给的是相对路径，且带行号
pub fn real_gleam_frame_file_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  let assert Ok(frames) = stacktrace.from_exception(e)

  let assert Ok(try_frame) = find_frame(frames, "error", "try")
  assert try_frame.location.file == Some("src/error.gleam")
  // 具体行号会随源码变动而漂移（见 Location.line 的说明），这里只确认有值
  assert try_frame.location.line != None
}

/// 手写 Erlang FFI 的帧给的是绝对路径（指向 build 目录里的拷贝）
pub fn real_erlang_frame_file_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  let assert Ok(frames) = stacktrace.from_exception(e)

  let assert Ok(ffi_frame) = find_frame(frames, "error_ffi", "try_func")
  let assert Some(file) = ffi_frame.location.file
  assert string.ends_with(file, "error_ffi.erl")
}

/// BIF 抛的帧：第三位是参数列表，location 没有 file/line。
///
/// 这条是回归测试 —— 曾经因为 dynamic.classify 的返回值大小写不匹配，
/// 参数列表被当成 arity 解析成了 0。
pub fn real_bif_frame_test() {
  let assert Error(e) = error.try(fn() { binary_to_integer(<<"x">>) })
  let assert Ok(frames) = stacktrace.from_exception(e)
  let assert Ok(first) = list.first(frames)

  assert first.module == "erlang"
  assert first.function == "binary_to_integer"

  case first.params {
    stacktrace.Arity(_) -> panic as "BIF 帧的第三位应该是参数列表，不是 arity"
    stacktrace.Args(args) -> {
      assert args == [dynamic.string("x")]
    }
  }

  assert first.location == stacktrace.Location(None, None)
}

/// 第一帧的 file 精确指向本测试文件
pub fn real_gleam_error_frame_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  let assert Ok(frames) = stacktrace.from_exception(e)
  let assert Ok(frame) = list.first(frames)
  assert frame.location.file == Some("test/stacktrace_test.gleam")
}

/// from_exception 只看 stacktrace，不看 reason
///
/// throw 的 reason 是普通值（不是 map），栈帧照样能解析。
pub fn from_exception_ignores_reason_test() {
  let assert Error(e) = error.try(fn() { throw("boom") })
  let assert Ok(frames) = stacktrace.from_exception(e)
  assert !list.is_empty(frames)
}
