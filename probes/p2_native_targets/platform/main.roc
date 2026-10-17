platform ""
    requires {
        main! : I64 => I64,
        app_id : Str,
    }
    exposes [Host]
    packages {}
    provides { "roc_main": main_for_host!, "roc_app_id": app_id_for_host }
    hosted {
        "roc_host_double": Host.double!,
    }
    targets: {
        inputs_dir: "targets/",
        x64musl: { inputs: ["host.o", app], output: Exe },
        x64openbsd: { inputs: ["crt0.o", "crtbegin.o", "host.o", app, "libc.so", "crtend.o"], output: Exe },
        arm64musl: { inputs: ["host.o", app], output: Exe },
        x64mac: { inputs: ["host.o", app], output: Exe },
        arm64mac: { inputs: ["host.o", app], output: Exe },
        x64win: { inputs: ["host.obj", app, "kernel32.lib"], output: Exe },
        arm64win: { inputs: ["host.obj", app, "kernel32.lib"], output: Exe },
    }

import Host

main_for_host! : I64 => I64
main_for_host! = |n| main!(n)

## Exposed only so the linker keeps the app's ROCOSMO_APP_ID marker.
app_id_for_host : {} -> Str
app_id_for_host = |{}| app_id
