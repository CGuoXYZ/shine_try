# shine_try

运行可能产生异常的函数

[![Package Version](https://img.shields.io/hexpm/v/shine_try)](https://hex.pm/packages/shine_try)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://shine-try.hexdocs.pm/)

```sh
gleam add shine_try
```
```gleam
import error

pub fn main() {
  // 运行一个可能产生异常的函数
  let result = error.try(fn() { panic as "故意引发的异常" })
  
  // 根据结果执行分支
  case result {
    Ok(val) -> // ...
    Error(_) -> // ...
  }
}
```

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
