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

// ───────────────────────── 手工构造栈帧 ─────────────────────────
//
// 真实的帧是 Erlang 4 元组 {Module, Function, ArityOrArgs, Location}，
// Location 是 proplist [{file, Charlist}, {line, Int}]。
// Gleam 的 decode.list 对元组也成立，所以用 List 构造等价结构。
// 这样就能精确制造真实异常里很难出现的形状（缺字段、顺序颠倒、垃圾帧……）。

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

// ─────────────────────── from_dynamic 的输入边界 ───────────────────────

/// 不是列表的输入不炸，直接给空列表
pub fn from_dynamic_non_list_test() {
  assert stacktrace.from_dynamic(dynamic.nil()) == []
  assert stacktrace.from_dynamic(dynamic.int(1)) == []
  assert stacktrace.from_dynamic(dynamic.string("nope")) == []
}

pub fn from_dynamic_empty_list_test() {
  assert stacktrace.from_dynamic(dynamic.list([])) == []
}

/// 解不出来的帧被跳过，而不是让整个解析失败
pub fn garbage_frames_are_skipped_test() {
  let input =
    dynamic.list([
      dynamic.int(1),
      dynamic.string("nope"),
      dynamic.list([dynamic.int(1)]),
      // 5 个元素，不是 4 元组
      dynamic.list([
        dynamic.int(1),
        dynamic.int(2),
        dynamic.int(3),
        dynamic.int(4),
        dynamic.int(5),
      ]),
      normal_frame(),
    ])

  let assert [only] = stacktrace.from_dynamic(input)
  assert only.module == "good_mod"
  assert only.function == "good_fun"
}

// ───────────────────── 第三位：arity 还是参数列表 ─────────────────────

pub fn arity_is_number_test() {
  let input = dynamic.list([frame("m", "f", dynamic.int(3), [])])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.arity == stacktrace.Arity(3)
}

pub fn arity_is_args_test() {
  let input =
    dynamic.list([frame("m", "f", dynamic.list([dynamic.string("x")]), [])])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.arity == stacktrace.Args([dynamic.string("x")])
}

/// 参数列表是空的时候也要走 Args，而不是掉进 Arity
pub fn arity_is_empty_args_test() {
  let input = dynamic.list([frame("m", "f", dynamic.list([]), [])])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.arity == stacktrace.Args([])
}

// ─────────────────────── location：按 key 找 ───────────────────────

pub fn location_file_and_line_test() {
  let input =
    dynamic.list([
      frame("m", "f", dynamic.int(0), [
        location_entry("file", charlist("src/a.gleam")),
        location_entry("line", dynamic.int(42)),
      ]),
    ])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.location == stacktrace.Location(Some("src/a.gleam"), Some(42))
}

/// line 在前、file 在后也要能解出来（不能写死下标）
pub fn location_order_independent_test() {
  let input =
    dynamic.list([
      frame("m", "f", dynamic.int(0), [
        location_entry("line", dynamic.int(7)),
        location_entry("file", charlist("src/b.gleam")),
      ]),
    ])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.location == stacktrace.Location(Some("src/b.gleam"), Some(7))
}

/// 只有 file 没有 line
pub fn location_missing_line_test() {
  let input =
    dynamic.list([
      frame("m", "f", dynamic.int(0), [
        location_entry("file", charlist("src/c.gleam")),
      ]),
    ])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.location == stacktrace.Location(Some("src/c.gleam"), None)
}

/// 只有 line 没有 file
pub fn location_missing_file_test() {
  let input =
    dynamic.list([
      frame("m", "f", dynamic.int(0), [location_entry("line", dynamic.int(9))]),
    ])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.location == stacktrace.Location(None, Some(9))
}

/// BIF / stdlib 抛的帧，location 里只有 error_info，没有 file/line
pub fn location_only_unknown_key_test() {
  let input =
    dynamic.list([
      frame("m", "f", dynamic.int(0), [
        location_entry("error_info", dynamic.string("whatever")),
      ]),
    ])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.location == stacktrace.Location(None, None)
}

/// 空 location
pub fn location_empty_test() {
  let input = dynamic.list([frame("m", "f", dynamic.int(0), [])])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.location == stacktrace.Location(None, None)
}

/// 多出来的未知 key 不影响 file/line 的解析
pub fn location_extra_key_ignored_test() {
  let input =
    dynamic.list([
      frame("m", "f", dynamic.int(0), [
        location_entry("error_info", dynamic.string("whatever")),
        location_entry("file", charlist("src/d.gleam")),
        location_entry("line", dynamic.int(1)),
      ]),
    ])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.location == stacktrace.Location(Some("src/d.gleam"), Some(1))
}

/// 非 ASCII 文件名：charlist 里是多字节码点，要按码点还原
pub fn location_non_ascii_file_test() {
  let input =
    dynamic.list([
      frame("m", "f", dynamic.int(0), [
        location_entry("file", charlist("测试/文件.gleam")),
        location_entry("line", dynamic.int(1)),
      ]),
    ])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.location == stacktrace.Location(Some("测试/文件.gleam"), Some(1))
}

/// file 不是 charlist 时给 None，而不是炸掉
pub fn location_weird_file_test() {
  let input =
    dynamic.list([
      frame("m", "f", dynamic.int(0), [location_entry("file", dynamic.int(123))]),
    ])
  let assert [f] = stacktrace.from_dynamic(input)
  assert f.location == stacktrace.Location(None, None)
}

// ──────────────────────────── 真实异常 ────────────────────────────

/// 第一帧就是抛出点：本测试模块里的匿名函数
pub fn real_panic_first_frame_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  let assert Ok(first) = list.first(error.stacktrace_from_exception(e))

  assert first.module == "stacktrace_test"
  assert string.contains(first.function, "anonymous")
}

/// 顺序：抛出点在最前面，error.try 在更外层
pub fn real_panic_frame_order_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  let frames = error.stacktrace_from_exception(e)

  let assert Ok(inner) = index_of_module(frames, "stacktrace_test")
  let assert Ok(try_index) = index_of_module(frames, "error")

  assert inner == 0
  assert inner < try_index
}

/// 来自 .gleam 源码的帧给的是相对路径，且带行号
pub fn real_gleam_frame_file_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  let frames = error.stacktrace_from_exception(e)

  let assert Ok(try_frame) = find_frame(frames, "error", "try")
  assert try_frame.location.file == Some("src/error.gleam")
  // 具体行号会随源码变动而漂移（见 Location.line 的说明），这里只确认有值
  assert try_frame.location.line != None
}

/// 手写 Erlang FFI 的帧给的是绝对路径（指向 build 目录里的拷贝）
pub fn real_erlang_frame_file_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  let frames = error.stacktrace_from_exception(e)

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
  let assert Ok(first) = list.first(error.stacktrace_from_exception(e))

  assert first.module == "erlang"
  assert first.function == "binary_to_integer"

  case first.arity {
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
  let assert Ok(frame) = list.first(error.stacktrace_from_exception(e))
  assert frame.location.file == Some("test/stacktrace_test.gleam")
}

/// stacktrace_from_exception 就是 from_dynamic(e.stacktrace)
pub fn stacktrace_from_exception_matches_from_dynamic_test() {
  let assert Error(e) = error.try(fn() { panic as "x" })
  assert error.stacktrace_from_exception(e)
    == stacktrace.from_dynamic(e.stacktrace)
}
