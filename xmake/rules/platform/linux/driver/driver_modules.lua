--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        driver_modules.lua
--

-- imports
import("core.base.option")
import("core.project.depend")
import("utils.progress")
import("private.tools.ccache")

-- get linux-headers sdk
function _get_linux_headers_sdk(target)
    local linux_headers = assert(target:pkg("linux-headers"), "please add `add_requires(\"linux-headers\", {configs = {driver_modules = true}})` and `add_packages(\"linux-headers\")` to the given target!")
    local includedirs = linux_headers:get("includedirs") or linux_headers:get("sysincludedirs")
    local version = linux_headers:version()
    local includedir
    local linux_headersdir
    for _, dir in ipairs(includedirs) do
        if dir:find("linux-headers", 1, true) then
            includedir = dir
            linux_headersdir = path.directory(dir)
            break
        end
    end
    assert(linux_headersdir, "linux-headers not found!")
    if not os.isfile(path.join(includedir, "generated/autoconf.h")) and
        not os.isfile(path.join(includedir, "config/auto.conf")) then
        raise("kernel configuration is invalid. include/generated/autoconf.h or include/config/auto.conf are missing.")
    end
    return {version = version, sdkdir = linux_headersdir, includedir = includedir}
end

-- get c system search include directory of gcc
--
-- e.g. gcc -E -Wp,-v -xc /dev/null
--
-- ignoring nonexistent directory "/usr/local/include/x86_64-linux-gnu"
-- ignoring nonexistent directory "/usr/lib/gcc/x86_64-linux-gnu/10/include-fixed"
-- ignoring nonexistent directory "/usr/lib/gcc/x86_64-linux-gnu/10/../../../../x86_64-linux-gnu/include"
-- #include "..." search starts here:
-- #include <...> search starts here:
-- /usr/lib/gcc/x86_64-linux-gnu/10/include        <-- we need get it
-- /usr/local/include
-- /usr/include/x86_64-linux-gnu
-- /usr/include
-- End of search list.
function _get_gcc_includedir(target)
    local includedir = _g.includedir
    if includedir == nil then
        local gcc, toolname = target:tool("cc")
        assert(toolname, "gcc")

        local _, result = try {function () return os.iorunv(gcc, {"-E", "-Wp,-v", "-xc", os.nuldev()}) end}
        if result then
            for _, line in ipairs(result:split("\n", {plain = true})) do
                line = line:trim()
                if os.isdir(line) then
                    includedir = line
                    break
                elseif line:startswith("End") then
                    break
                end
            end
        end
        _g.includedir = includedir or false
    end
    return includedir or nil
end

function load(target)
    -- we need only need binary kind, because we will rewrite on_link
    target:set("kind", "binary")
    target:set("extension", ".ko")

    -- get and save linux-headers sdk
    local linux_headers = _get_linux_headers_sdk(target)
    target:data_set("linux.driver.linux_headers", linux_headers)

    -- check compiler, we must use gcc
    assert(target:has_tool("cc", "gcc"), "we must use gcc compiler!")

    -- check rules
    for _, rulename in ipairs({"mode.release", "mode.debug", "mode.releasedbg", "mode.minsizerel", "mode.asan", "mode.tsan"}) do
        assert(not target:rule(rulename), "target(%s) is linux driver module, it need not rule(%s)!", target:name(), rulename)
    end

    -- add includedirs
    local sdkdir = linux_headers.sdkdir
    local includedir = linux_headers.includedir
    local archsubdir
    if target:is_arch("x86_64", "i386") then
        archsubdir = path.join(sdkdir, "arch", "x86")
    elseif target:is_arch("arm", "armv7") then
        archsubdir = path.join(sdkdir, "arch", "arm")
    elseif target:is_arch("arm64", "arm64-v8a") then
        archsubdir = path.join(sdkdir, "arch", "arm64")
    else
        raise("rule(platform.linux.driver): unsupported arch(%s)!", target:arch())
    end
    assert(archsubdir, "unknown arch(%s) for linux driver modules!", target:arch())
    local gcc_includedir = _get_gcc_includedir(target)
    if gcc_includedir then
        target:add("sysincludedirs", gcc_includedir)
    end
    target:add("includedirs", path.join(archsubdir, "include"))
    target:add("includedirs", path.join(archsubdir, "include", "generated"))
    target:add("includedirs", includedir)
    target:add("includedirs", path.join(archsubdir, "include", "uapi"))
    target:add("includedirs", path.join(archsubdir, "include", "generated", "uapi"))
    target:add("includedirs", path.join(includedir, "uapi"))
    target:add("includedirs", path.join(includedir, "generated", "uapi"))
    target:add("cflags", "-include " .. path.join(includedir, "linux", "kconfig.h"))
    target:add("cflags", "-include " .. path.join(includedir, "linux", "compiler_types.h"))
    -- we need disable includedirs from add_packages("linux-headers")
    target:pkg("linux-headers"):set("includedirs", nil)
    target:pkg("linux-headers"):set("sysincludedirs", nil)

    -- add compilation flags
    target:set("policy", "check.auto_ignore_flags", false)
    target:add("defines", "__KERNEL__", "MODULE")
    target:add("defines", "KBUILD_MODNAME=\"" .. target:name() .. "\"")
    for _, sourcefile in ipairs(target:sourcefiles()) do
        target:fileconfig_set(sourcefile, {defines = "KBUILD_BASENAME=\"" .. path.basename(sourcefile) .. "\""})
    end
    target:set("optimize", "faster") -- we need use -O2 for gcc
    if not target:get("language") then
        target:set("languages", "gnu89")
    end
    target:add("cflags", "-nostdinc")
    target:add("cflags", "-fno-strict-aliasing", "-fno-common", "-fshort-wchar", "-fno-PIE")
    target:add("cflags", "-falign-jumps=1", "-falign-loops=1", "-fno-asynchronous-unwind-tables")
    target:add("cflags", "-fno-jump-tables", "-fno-delete-null-pointer-checks")
    target:add("cflags", "-fno-reorder-blocks", "-fno-ipa-cp-clone", "-fno-partial-inlining", "-fstack-protector-strong")
    target:add("cflags", "-fno-inline-functions-called-once", "-falign-functions=32")
    target:add("cflags", "-fno-strict-overflow", "-fno-stack-check", "-fconserve-stack")
    if target:is_arch("x86_64", "i386") then
        target:add("defines", "CONFIG_X86_X32_ABI")
        target:add("cflags", "-mno-sse", "-mno-mmx", "-mno-sse2", "-mno-3dnow", "-mno-avx", "-mno-80387", "-mno-fp-ret-in-387")
        target:add("cflags", "-mpreferred-stack-boundary=3", "-mskip-rax-setup", "-mtune=generic", "-mno-red-zone", "-mcmodel=kernel")
        target:add("cflags", "-mindirect-branch=thunk-extern", "-mindirect-branch-register", "-mrecord-mcount")
        target:add("cflags", "-fmacro-prefix-map=./=", "-fcf-protection=none", "-fno-allow-store-data-races")
    elseif target:is_arch("arm", "armv7") then
        target:add("cflags", "-mbig-endian", "-mabi=aapcs-linux", "-mfpu=vfp", "-marm", "-march=armv6k", "-mtune=arm1136j-s", "-msoft-float", "-Uarm")
        target:add("defines", "__LINUX_ARM_ARCH__=6")
    elseif target:is_arch("arm64", "arm64-v8a") then
        target:add("cflags", "-mlittle-endian", "-mgeneral-regs-only", "-mabi=lp64")
    end

    -- add optional flags (fentry)
    local has_fentry = target:values("linux.driver.fentry")
    if has_fentry then
        target:add("cflags", "-mfentry")
        target:add("defines", "CC_USING_FENTRY")
    end

    -- add optional flags (asan)
    local has_asan = target:values("linux.driver.asan")
    if has_asan then
        target:add("cflags", "-fsanitize=kernel-address")
        target:add("cflags", "-fasan-shadow-offset=0xdffffc0000000000", "-fsanitize-coverage=trace-pc", "-fsanitize-coverage=trace-cmp")
        target:add("cflags", "--param asan-globals=1", "--param asan-instrumentation-with-call-threshold=0", "--param asan-stack=1", "--param asan-instrument-allocas=1")
    end
end

function link(target, opt)
    local targetfile  = target:targetfile()
    local dependfile  = target:dependfile(targetfile)
    local objectfiles = target:objectfiles()
    depend.on_changed(function ()

        -- trace
        progress.show(opt.progress, "${color.build.object}linking.$(mode) %s", targetfile)

        -- get module scripts
        local modpost, ldscriptfile
        local linux_headers = target:data("linux.driver.linux_headers")
        if linux_headers then
            modpost = path.join(linux_headers.sdkdir, "scripts", "mod", "modpost")
            ldscriptfile = path.join(linux_headers.sdkdir, "scripts", "module.lds")
        end
        assert(modpost and os.isfile(modpost), "scripts/mod/modpost not found!")
        assert(ldscriptfile and os.isfile(ldscriptfile), "scripts/module.lds not found!")

        -- get ld
        local ld = target:tool("ld")
        assert(ld, "ld not found!")
        ld = ld:gsub("gcc$", "ld")
        ld = ld:gsub("g%+%+$", "ld")

        -- link target.o
        local argv = {}
        if target:is_arch("x86_64", "i386") then
            table.join2(argv, "-m", "elf_" .. target:arch())
        elseif target:is_arch("arm", "armv7") then
            table.join2(argv, "-EB")
        elseif target:is_arch("arm64", "arm64-v8a") then
            table.join2(argv, "-EL", "-maarch64elf")
        end
        local targetfile_o = target:objectfile(targetfile)
        table.join2(argv, "-r", "-o", targetfile_o)
        table.join2(argv, objectfiles)
        os.mkdir(path.directory(targetfile_o))
        os.vrunv(ld, argv)

        -- generate target.mod
        local targetfile_mod = targetfile_o:gsub("%.o$", ".mod")
        io.writefile(targetfile_mod, table.concat(objectfiles, " ") .. "\n\n")

        -- generate .sourcename.o.cmd
        -- we need only touch an empty file, otherwise modpost command will raise error.
        for _, objectfile in ipairs(objectfiles) do
            local objectdir = path.directory(objectfile)
            local objectname = path.filename(objectfile)
            local cmdfile = path.join(objectdir, "." .. objectname .. ".cmd")
            io.writefile(cmdfile, "")
        end

        -- generate target.mod.c
        local orderfile = path.join(path.directory(targetfile_o), "modules.order")
        local symversfile = path.join(path.directory(targetfile_o), "Module.symvers")
        argv = {"-m", "-a", "-o", symversfile, "-e", "-N", "-T", "-"}
        io.writefile(orderfile, targetfile_o .. "\n")
        os.vrunv(modpost, argv, {stdin = orderfile})

        -- compile target.mod.c
        local targetfile_mod_c = targetfile_o:gsub("%.o$", ".mod.c")
        local targetfile_mod_o = targetfile_o:gsub("%.o$", ".mod.o")
        local compinst = target:compiler("cc")
        if option.get("verbose") then
            print(compinst:compcmd(targetfile_mod_c, targetfile_mod_o, {target = target, rawargs = true}))
        end
        assert(compinst:compile(targetfile_mod_c, targetfile_mod_o, {target = target}))

        -- link target.ko
        argv = {}
        if target:is_arch("x86_64", "i386") then
            table.join2(argv, "-m", "elf_" .. target:arch())
        elseif target:is_arch("arm", "armv7") then
            table.join2(argv, "-EB", "--be8")
        elseif target:is_arch("arm64", "arm64-v8a") then
            table.join2(argv, "-EL", "-maarch64elf")
        end
        local targetfile_o = target:objectfile(targetfile)
        table.join2(argv, "-r", "--build-id=sha1", "-T", ldscriptfile, "-o", targetfile, targetfile_o, targetfile_mod_o)
        os.mkdir(path.directory(targetfile))
        os.vrunv(ld, argv)

    end, {dependfile = dependfile, lastmtime = os.mtime(target:targetfile()), files = objectfiles})
end