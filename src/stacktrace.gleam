import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

import error.{type Exception}

/// 栈帧列表
pub type StackFrameList =
  List(StackFrame)

/// 栈帧
pub type StackFrame {
  /// module: 模块
  /// 
  /// func: 函数
  /// 
  /// arity: 参数数量/列表
  /// 
  /// location: 位置
  StackFrame(
    module: String,
    function: String,
    params: Params,
    location: Location,
  )
}

/// 参数数量/列表
pub type Params {
  /// 参数数量
  Arity(Int)
  /// 参数列表
  Args(List(Dynamic))
}

/// 位置
pub type Location {
  /// file: 文件
  /// 
  /// line: 行号(仅供参考)
  Location(file: Option(String), line: Option(Int))
}

/// 从Exception获取StackFrameList
/// 
/// 由于类型是公开的，你完全可以伪造一个Stacktrace
pub fn from_exception(ex: Exception) -> Result(StackFrameList, Nil) {
  case decode.run(ex.stacktrace, decode.list(decode.dynamic)) {
    Error(_) -> Error(Nil)
    Ok(stacktrace) -> list.try_map(stacktrace, parse_frame)
  }
}

fn parse_frame(frame: Dynamic) -> Result(StackFrame, Nil) {
  // [
  //   [atom, atom, int, [[[atom, charlist]], [[atom, int]]]], 
  //   ..
  // ]
  use frame <- result.try(case decode.run(frame, decode.list(decode.dynamic)) {
    Error(_) -> Error(Nil)
    Ok(frame) -> Ok(frame)
  })
  case frame {
    [module, function, arity, location] ->
      StackFrame(
        module: atom_to_string(module, "?"),
        function: atom_to_string(function, "?"),
        params: parse_params(arity),
        location: parse_location(location),
      )
      |> Ok()
    _ -> Error(Nil)
  }
}

fn parse_params(arity: Dynamic) -> Params {
  case decode.run(arity, decode.int) {
    Ok(arity) -> Arity(arity)
    Error(_) ->
      case decode.run(arity, decode.list(decode.dynamic)) {
        Ok(args) -> Args(args)
        Error(_) -> Args([])
      }
  }
}

fn parse_location(location: Dynamic) -> Location {
  case decode.run(location, decode.list(decode.dynamic)) {
    Error(_) -> Location(None, None)
    Ok(location) ->
      list.fold(location, Location(None, None), fn(acc, entry) {
        case decode.run(entry, decode.list(decode.dynamic)) {
          Ok([k, v]) ->
            case atom_to_string(k, "") {
              "line" -> Location(..acc, line: dyn_to_int(v))
              "file" -> Location(..acc, file: charlist_to_string(v))
              _ -> acc
            }
          _ -> acc
        }
      })
  }
}

fn atom_to_string(atom: Dynamic, fallback: String) -> String {
  case decode.run(atom, atom.decoder()) {
    Ok(atom) -> atom.to_string(atom)
    Error(_) -> fallback
  }
}

fn dyn_to_int(dyn: Dynamic) -> Option(Int) {
  case decode.run(dyn, decode.int) {
    Error(_) -> None
    Ok(int) -> Some(int)
  }
}

fn charlist_to_string(charlist: Dynamic) -> Option(String) {
  case decode.run(charlist, decode.list(decode.int)) {
    Error(_) -> None
    Ok(charlist) ->
      case result.all(list.map(charlist, string.utf_codepoint)) {
        Error(_) -> None
        Ok(codepoints) -> string.from_utf_codepoints(codepoints) |> Some()
      }
  }
}
