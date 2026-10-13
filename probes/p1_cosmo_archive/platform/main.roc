platform ""
    requires {
        main! : I64 => I64
    }
    exposes [Host]
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_host_double": Host.double!,
    }
    targets: {
        x64musl: { inputs: [app], output: Archive },
        arm64musl: { inputs: [app], output: Archive },
    }

import Host

main_for_host! : I64 => I64
main_for_host! = |n| main!(n)
