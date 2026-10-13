app [main!, app_id] { pf: platform "./platform/main.roc" }

## Cache namespace for rocosmo (reverse-DNS, ends with ";").
app_id : Str
app_id = "ROCOSMO_APP_ID=dev.rocosmo.probe;"

import pf.Host

main! : I64 => I64
main! = |n| {
    # A runtime list allocates, exercising the host's roc_alloc.
    list = [n, n, n]
    total = list.fold(0, |acc, elem| acc + elem)
    Host.double!(total) + 1
}
