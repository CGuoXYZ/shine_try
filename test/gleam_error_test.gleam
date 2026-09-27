import error
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam_error

// ─────────────────────── 构造输入 ───────────────────────
//
// 真实的 reason 是 atom 键的 Erlang map，Gleam 里写不出 map 字面量，
// 所以用 maps:from_list 手工构造，用来覆盖真实异常里很难造的形状
// （缺字段、未知的 gleam_error 值……）。

@external(erlang, "maps", "from_list")
fn make_map(pairs: List(#(Atom, Dynamic))) -> Dynamic

@external(erlang, "erlang", "binary_to_integer")
fn binary_to_integer(bits: BitArray) -> Int

@external(erlang, "erlang", "throw")
fn throw(value: a) -> b

fn entry(key: String, value: Dynamic) -> #(Atom, Dynamic) {
  #(atom.create(key), value)
}

fn atom_dyn(name: String) -> Dynamic {
  atom.to_dynamic(atom.create(name))
}

/// 完整的「基础信息」：五个字段齐全
fn basic_entries() -> List(#(Atom, Dynamic)) {
  [
    entry("module", dynamic.string("mod")),
    entry("file", dynamic.string("src/x.gleam")),
    entry("function", dynamic.string("fn")),
    entry("line", dynamic.int(7)),
    entry("message", dynamic.string("msg")),
  ]
}

/// 用手工构造的 reason map 走一遍解析
fn from_reason(
  pairs: List(#(Atom, Dynamic)),
) -> Result(gleam_error.GleamError, Nil) {
  gleam_error.from_exception(error.Exception(
    class: dynamic.nil(),
    reason: make_map(pairs),
    stacktrace: dynamic.nil(),
  ))
}

// ─────────────── 制造真实异常用的小函数 ───────────────

fn panics() -> a {
  panic as "炸了"
}

fn todos() -> a {
  todo as "未完成"
}

fn falsy() -> Bool {
  False
}

fn falsy2(x: Int, s: String) -> Bool {
  let _ = x
  let _ = s
  False
}

fn one() -> Int {
  1
}

fn parsed(f: fn() -> a) -> Result(gleam_error.GleamError, Nil) {
  let assert Error(e) = error.try(f)
  gleam_error.from_exception(e)
}

fn must_parse(f: fn() -> a) -> gleam_error.GleamError {
  let assert Ok(ge) = parsed(f)
  ge
}

fn variant(ge: gleam_error.GleamError) -> String {
  case ge {
    gleam_error.Panic(_) -> "Panic"
    gleam_error.Todo(_) -> "Todo"
    gleam_error.AssertSingle(_, _) -> "AssertSingle"
    gleam_error.AssertFuncCall(_, _) -> "AssertFuncCall"
    gleam_error.AssertPair(_, _, _, _) -> "AssertPair"
    gleam_error.LetAssert(_, _) -> "LetAssert"
  }
}

// ═══════════════════ 真实异常：六个变体 ═══════════════════

/// panic：只有基础信息
pub fn panic_test() {
  let ge = must_parse(panics)

  assert variant(ge) == "Panic"
  let assert gleam_error.Panic(basic) = ge
  assert basic.message == "炸了"
  // function 是「包含 panic 的那个具名函数」，比 stacktrace 的匿名函数名友好
  assert basic.function == "panics"
  assert basic.module == "gleam_error_test"
  assert basic.file == "test/gleam_error_test.gleam"
  assert basic.line > 0
}

pub fn todo_test() {
  let ge = must_parse(todos)

  assert variant(ge) == "Todo"
  let assert gleam_error.Todo(basic) = ge
  assert basic.message == "未完成"
  assert basic.function == "todos"
}

/// assert 的 `assert val` 形式：带上被断言的值
pub fn assert_single_test() {
  let flag = False
  let ge =
    must_parse(fn() {
      assert flag
    })

  assert variant(ge) == "AssertSingle"
  let assert gleam_error.AssertSingle(basic, value) = ge
  assert basic.message == "Assertion failed."
  assert value == dynamic.bool(False)
}

/// assert 的 `assert func()` 形式：没有参数时是空列表
pub fn assert_func_call_without_args_test() {
  let ge =
    must_parse(fn() {
      assert falsy()
    })

  assert variant(ge) == "AssertFuncCall"
  let assert gleam_error.AssertFuncCall(_, arguments) = ge
  assert arguments == []
}

/// assert 的 `assert func(a, b)` 形式：带上参数值，且保持原顺序
pub fn assert_func_call_with_args_test() {
  let ge =
    must_parse(fn() {
      assert falsy2(1, "x")
    })

  assert variant(ge) == "AssertFuncCall"
  let assert gleam_error.AssertFuncCall(_, arguments) = ge
  assert arguments == [dynamic.int(1), dynamic.string("x")]
}

/// assert 的 `assert a == b` 形式：左右值 + 运算符
pub fn assert_pair_test() {
  let a = 1
  let b = 3
  let ge =
    must_parse(fn() {
      assert a == b
    })

  assert variant(ge) == "AssertPair"
  let assert gleam_error.AssertPair(_, left, right, operator) = ge
  assert left == dynamic.int(1)
  assert right == dynamic.int(3)
  assert operator == "=="
}

/// 操作数是函数调用时，仍然是「成对比较」，不能判成 AssertFuncCall
///
/// 编译器只在 `assert func()` 这种顶层调用形式里给 arguments；
/// `assert func() == 2` 给的是 left/right/operator。这条是判形的回归测试。
pub fn assert_pair_with_call_operand_test() {
  let ge =
    must_parse(fn() {
      assert one() == 2
    })

  assert variant(ge) == "AssertPair"
  let assert gleam_error.AssertPair(_, left, right, operator) = ge
  assert left == dynamic.int(1)
  assert right == dynamic.int(2)
  assert operator == "=="
}

/// let assert：带上匹配失败的值
pub fn let_assert_test() {
  let ge =
    must_parse(fn() {
      let assert [_] = [3, 4]
    })

  assert variant(ge) == "LetAssert"
  let assert gleam_error.LetAssert(basic, value) = ge
  assert basic.message != ""
  assert value == dynamic.list([dynamic.int(3), dynamic.int(4)])
}

// ═══════════════ 非 Gleam 异常：解不出来 ═══════════════

/// Erlang 原生错误的 reason 是 atom，不是 map
pub fn erlang_error_is_not_gleam_error_test() {
  assert parsed(fn() { binary_to_integer(<<"x">>) }) == Error(Nil)
}

/// throw 的 reason 是被抛出的值
pub fn throw_is_not_gleam_error_test() {
  assert parsed(fn() { throw("boom") }) == Error(Nil)
}

/// reason 不是 map（手工构造的几种 Dynamic）
pub fn reason_not_map_test() {
  assert from_reason([]) == Error(Nil)

  let assert Error(_) =
    gleam_error.from_exception(error.Exception(
      class: dynamic.nil(),
      reason: dynamic.string("boom"),
      stacktrace: dynamic.nil(),
    ))
}

// ═══════════════ 手工构造：判形与严格性 ═══════════════

/// 只有 expression → AssertSingle
pub fn handbuilt_single_test() {
  let assert Ok(ge) =
    from_reason([
      entry("gleam_error", atom_dyn("assert")),
      entry("expression", make_map([entry("value", dynamic.int(9))])),
      ..basic_entries()
    ])

  let assert gleam_error.AssertSingle(_, value) = ge
  assert value == dynamic.int(9)
}

/// 只有 arguments → AssertFuncCall
///
/// arguments 的元素必须是表达式字典（编译器给的形状），
/// 库会把每个元素的 value 取出来。
pub fn handbuilt_func_call_test() {
  let assert Ok(ge) =
    from_reason([
      entry("gleam_error", atom_dyn("assert")),
      entry(
        "arguments",
        dynamic.list([
          make_map([entry("value", dynamic.int(1))]),
          make_map([entry("value", dynamic.string("x"))]),
        ]),
      ),
      ..basic_entries()
    ])

  let assert gleam_error.AssertFuncCall(_, arguments) = ge
  assert arguments == [dynamic.int(1), dynamic.string("x")]
}

/// 只有 left / right / operator → AssertPair
pub fn handbuilt_pair_test() {
  let assert Ok(ge) =
    from_reason([
      entry("gleam_error", atom_dyn("assert")),
      entry("left", make_map([entry("value", dynamic.int(1))])),
      entry("right", make_map([entry("value", dynamic.int(2))])),
      entry("operator", atom_dyn(">")),
      ..basic_entries()
    ])

  let assert gleam_error.AssertPair(_, left, right, operator) = ge
  assert left == dynamic.int(1)
  assert right == dynamic.int(2)
  assert operator == ">"
}

/// 三个形态都没有 → 解不出来
pub fn handbuilt_assert_without_detail_test() {
  let assert Error(Nil) =
    from_reason([entry("gleam_error", atom_dyn("assert")), ..basic_entries()])
}

/// 基础信息缺一个字段就整条解不出来
pub fn basic_info_is_all_or_nothing_test() {
  let without_message = [
    entry("gleam_error", atom_dyn("panic")),
    entry("module", dynamic.string("mod")),
    entry("file", dynamic.string("src/x.gleam")),
    entry("function", dynamic.string("fn")),
    entry("line", dynamic.int(7)),
  ]
  assert from_reason(without_message) == Error(Nil)

  let without_line = [
    entry("gleam_error", atom_dyn("panic")),
    entry("module", dynamic.string("mod")),
    entry("file", dynamic.string("src/x.gleam")),
    entry("function", dynamic.string("fn")),
    entry("message", dynamic.string("msg")),
  ]
  assert from_reason(without_line) == Error(Nil)
}

/// 成对比较缺 operator → 解不出来
pub fn pair_without_operator_test() {
  let assert Error(Nil) =
    from_reason([
      entry("gleam_error", atom_dyn("assert")),
      entry("left", make_map([entry("value", dynamic.int(1))])),
      entry("right", make_map([entry("value", dynamic.int(2))])),
      ..basic_entries()
    ])
}

/// let assert 缺 value → 解不出来
pub fn let_assert_without_value_test() {
  let assert Error(Nil) =
    from_reason([
      entry("gleam_error", atom_dyn("let_assert")),
      ..basic_entries()
    ])
}

/// 未知的 gleam_error 值 → 解不出来
///
/// 注意：它和「根本不是 Gleam 错误」返回的是同一个 Error(Nil)，
/// 如果编译器将来加了新的异常类型，用户看到的就是这个结果。
pub fn unknown_gleam_error_value_test() {
  assert from_reason([entry("gleam_error", atom_dyn("mystery"))]) == Error(Nil)
}

/// 没有 gleam_error 键 → 解不出来
pub fn missing_gleam_error_key_test() {
  assert from_reason(basic_entries()) == Error(Nil)
}

/// 多出来的键被忽略（将来编译器加字段也不会让解析失败）
pub fn extra_keys_are_ignored_test() {
  let assert Ok(ge) =
    from_reason([
      entry("gleam_error", atom_dyn("panic")),
      entry("start", dynamic.int(1)),
      entry("end", dynamic.int(2)),
      entry("expression_start", dynamic.int(3)),
      ..basic_entries()
    ])

  assert variant(ge) == "Panic"
}

// ═══════════ 参数列表里装的是什么（当前实现的事实）═══════════
//
// 编译器给出的 arguments 元素是「表达式字典」（内含 value / kind / start / end），
// 库会把每个元素的 value 取出来，所以 AssertFuncCall 拿到的是参数值本身。

pub fn arguments_are_values_test() {
  let ge =
    must_parse(fn() {
      assert falsy2(1, "y")
    })
  let assert gleam_error.AssertFuncCall(_, arguments) = ge

  assert arguments == [dynamic.int(1), dynamic.string("y")]
}

/// 参数本身是函数调用时，取到的也是它的值
pub fn arguments_with_call_argument_test() {
  let ge =
    must_parse(fn() {
      assert falsy2(one(), "x")
    })
  let assert gleam_error.AssertFuncCall(_, arguments) = ge

  assert arguments == [dynamic.int(1), dynamic.string("x")]
}

/// 参数元素缺 value → 整条解析失败（全有或全无）
///
/// 真实异常里不会出现（编译器总会给 value），
/// 这条锁的是实现语义：只要有一个参数取不出 value，就不是 AssertFuncCall。
pub fn arguments_missing_value_test() {
  let assert Error(Nil) =
    from_reason([
      entry("gleam_error", atom_dyn("assert")),
      entry(
        "arguments",
        dynamic.list([
          make_map([entry("kind", atom_dyn("expression"))]),
          make_map([entry("value", dynamic.int(2))]),
        ]),
      ),
      ..basic_entries()
    ])
}
