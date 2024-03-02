(module
  (func $add (param $a i32) (param $b i32) (result i32)
    (local $my_value i32)
    i32.const 5
    local.set $my_value
    local.get $a
    local.get $b
    local.get $my_value
    i32.add
    i32.add
  )
  (export "add" (func $add))
)
