const std = @import("std");
const Builder = std.build.Builder;
const builtin = std.builtin;
const assert = std.debug.assert;

const Context = enum {
  kernel,
  blobspace,
  userspace,
};

var source_blob: *std.build.RunStep = undefined;
var source_blob_path: []u8 = undefined;

fn make_source_blob(b: *Builder) void {
  source_blob_path = b.fmt("{}/sources.tar", .{b.cache_root});

  source_blob = b.addSystemCommand(
    &[_][]const u8 {
      "tar", "--no-xattrs", "-cf", source_blob_path, "src", "build.zig",
    },
  );
}

fn target(exec: *std.build.LibExeObjStep, arch: builtin.Arch, context: Context) void {
  var disabled_features = std.Target.Cpu.Feature.Set.empty;
  var enabled_feautres  = std.Target.Cpu.Feature.Set.empty;

  switch(arch) {
    .x86_64 => {
      const features = std.Target.x86.Feature;
      if(context == .kernel) {
        // Disable SIMD registers
        disabled_features.addFeature(@enumToInt(features.mmx));
        disabled_features.addFeature(@enumToInt(features.sse));
        disabled_features.addFeature(@enumToInt(features.sse2));
        disabled_features.addFeature(@enumToInt(features.avx));
        disabled_features.addFeature(@enumToInt(features.avx2));

        enabled_feautres.addFeature(@enumToInt(features.soft_float));
        exec.code_model = .kernel;
      } else {
        exec.code_model = .small;
      }
    },
    .aarch64 => {
      const features = std.Target.aarch64.Feature;
      if(context == .kernel) {
        // This is equal to -mgeneral-regs-only
        disabled_features.addFeature(@enumToInt(features.fp_armv8));
        disabled_features.addFeature(@enumToInt(features.crypto));
        disabled_features.addFeature(@enumToInt(features.neon));
      }
      exec.code_model = .small;
    },
    .riscv64 => {
      // idfk
      exec.code_model = .small;
    },
    else => unreachable,
  }

  exec.disable_stack_probing = switch(context) {
    .kernel => true,
    .blobspace => true,
    else => false,
  };

  exec.setTarget(.{
    .cpu_arch = arch,
    .os_tag = std.Target.Os.Tag.freestanding,
    .abi = std.Target.Abi.none,
    .cpu_features_sub = disabled_features,
    .cpu_features_add = enabled_feautres,
  });
}

fn add_libs(exec: *std.build.LibExeObjStep) void {
  exec.addPackage(.{
    .name = "rb",
    .path = "src/external/std-lib-orphanage/std/rb.zig",
  });
}

fn make_exec(b: *Builder, arch: builtin.Arch, ctx: Context, filename: []const u8, main: []const u8) *std.build.LibExeObjStep {
  const exec = b.addExecutable(filename, main);
  exec.addBuildOption([] const u8, "source_blob_path", b.fmt("../../{}", .{source_blob_path}));
  target(exec, arch, ctx);
  add_libs(exec);
  exec.setBuildMode(.ReleaseSafe);
  exec.strip = false;
  exec.setMainPkgPath("src/");
  exec.setOutputDir(b.cache_root);

  exec.install();

  exec.step.dependOn(&source_blob.step);

  return exec;
}

fn build_kernel(b: *Builder, arch: builtin.Arch, name: []const u8) *std.build.LibExeObjStep {
  const kernel_filename = b.fmt("Zigger_{}_{}", .{name, @tagName(arch)});
  const main_file       = b.fmt("src/boot/{}.zig", .{name});

  const kernel = make_exec(b, arch, .kernel, kernel_filename, main_file);
  kernel.addAssemblyFile(b.fmt("src/boot/{}_{}.asm", .{name, @tagName(arch)}));
  kernel.setLinkerScriptPath("src/kernel/kernel.ld");

  //kernel.step.dependOn(&build_dyld(b, arch).step);

  return kernel;
}

fn build_dyld(b: *Builder, arch: builtin.Arch) *std.build.LibExeObjStep {
  const dyld_filename = b.fmt("Dyld_", .{@tagName(arch)});

  const dyld = make_exec(b, arch, .blobspace, dyld_filename, "src/userspace/dyld/dyld.zig");
  dyld.setLinkerScriptPath("src/userspace/dyld/dyld.ld");

  return dyld;
}

fn qemu_run_aarch64_sabaton(b: *Builder, board_name: []const u8, desc: []const u8, dep: *std.build.LibExeObjStep) void {
  const command_step = b.step(board_name, desc);

  const params =
    &[_][]const u8 {
      "qemu-system-aarch64",
      "-M", board_name,
      "-cpu", "cortex-a57",
      "-drive", b.fmt("if=pflash,format=raw,file=Sabaton/out/aarch64_{}.bin,readonly=on", .{board_name}),
      "-drive", b.fmt("if=pflash,format=raw,file={},readonly=on", .{dep.getOutputPath()}),
      "-m", "4G",
      "-serial", "stdio",
      //"-S", "-s",
      "-d", "int",
      "-smp", "4",
      "-device", "virtio-gpu-pci",
    };

  const pad_step = b.addSystemCommand(
    &[_][]const u8 {
      "truncate", "-s", "64M", dep.getOutputPath(),
    },
  );

  const run_step = b.addSystemCommand(params);
  pad_step.step.dependOn(&dep.step);
  run_step.step.dependOn(&pad_step.step);
  command_step.dependOn(&run_step.step);
}

fn qemu_run_riscv_sabaton(b: *Builder, board_name: []const u8, desc: []const u8, dep: *std.build.LibExeObjStep) void {
  const command_step = b.step(board_name, desc);

  const params =
    &[_][]const u8 {
      "qemu-system-riscv64",
      "-M", board_name,
      "-cpu", "rv64",
      "-drive", b.fmt("if=pflash,format=raw,file=Sabaton/out/riscv64_{}.bin,readonly=on", .{board_name}),
      "-drive", b.fmt("if=pflash,format=raw,file={},readonly=on", .{dep.getOutputPath()}),
      "-m", "4G",
      "-serial", "stdio",
      //"-S", "-s",
      "-d", "int",
      "-smp", "4",
      "-device", "virtio-gpu-pci",
    };

  const pad_step = b.addSystemCommand(
    &[_][]const u8 {
      "truncate", "-s", "64M", dep.getOutputPath(),
    },
  );

  const run_step = b.addSystemCommand(params);
  pad_step.step.dependOn(&dep.step);
  run_step.step.dependOn(&pad_step.step);
  command_step.dependOn(&run_step.step);
}

fn qemu_run_image_x86_64(b: *Builder, image_path: []const u8) *std.build.RunStep {
  const run_params =
    &[_][]const u8 {
      "qemu-system-x86_64",
      "-drive",
      b.fmt("format=raw,file={}", .{image_path}),
      "-debugcon", "stdio",
      //"-serial", "stdio",
      "-m", "4G",
      "-no-reboot",
      "-machine", "q35",
      "-device", "qemu-xhci",
      "-smp", "8",
      //"-cpu", "host", "-enable-kvm",
      //"-d", "int",
      //"-s", "-S",
      //"-trace", "ahci_*",
    };
  return b.addSystemCommand(run_params);
}

fn echfs_image(b: *Builder, image_path: []const u8, kernel_path: []const u8, install_command: []const u8) *std.build.RunStep {
  const image_params =
    &[_][]const u8 {
      "/bin/sh", "-c",
      std.mem.concat(b.allocator, u8, &[_][]const u8{
        "rm ", image_path, " || true && ",
        "dd if=/dev/zero bs=1048576 count=0 seek=8 of=", image_path, " && ",
        "parted -s ", image_path, " mklabel msdos && ",
        "parted -s ", image_path, " mkpart primary 1 100% && ",
        "parted -s ", image_path, " set 1 boot on && ",
        "echfs-utils -m -p0 ", image_path, " quick-format 32768 && ",
        "echfs-utils -m -p0 ", image_path, " import '", kernel_path, "' Zigger.elf && ",
        install_command,
      }) catch unreachable,
    };
  return b.addSystemCommand(image_params);
}

fn qloader_target(b: *Builder, command: []const u8, desc: []const u8, image_path: []const u8, dep: *std.build.LibExeObjStep) void {
  assert(dep.target.cpu_arch.? == .x86_64);

  const command_step = b.step(command, desc);
  const run_step = qemu_run_image_x86_64(b, image_path);
  const image_step = echfs_image(b, image_path, dep.getOutputPath(),
    std.mem.concat(b.allocator, u8, &[_][]const u8{
      "echfs-utils -m -p0 ", image_path, " import qloader_image/qloader2.cfg qloader2.cfg && ",
      "./qloader2/qloader2-install ./qloader2/qloader2.bin ", image_path
    }) catch unreachable);

  image_step.step.dependOn(&dep.step);
  run_step.step.dependOn(&image_step.step);
  command_step.dependOn(&run_step.step);
}

fn limine_target(b: *Builder, command: []const u8, desc: []const u8, image_path: []const u8, dep: *std.build.LibExeObjStep) void {
  assert(dep.target.cpu_arch.? == .x86_64);

  const command_step = b.step(command, desc);
  const run_step = qemu_run_image_x86_64(b, image_path);
  const image_step = echfs_image(b, image_path, dep.getOutputPath(),
    std.mem.concat(b.allocator, u8, &[_][]const u8{
      "make -C limine limine-install && ",
      "echfs-utils -m -p0 ", image_path, " import limine_image/limine.cfg limine.cfg && ",
      "./limine/limine-install ./limine/limine.bin ", image_path
    }) catch unreachable);

  image_step.step.dependOn(&dep.step);
  run_step.step.dependOn(&image_step.step);
  command_step.dependOn(&run_step.step);
}

pub fn build(b: *Builder) void {
  const sources = make_source_blob(b);

  qemu_run_aarch64_sabaton(b,
    "raspi3",
    "(WIP) Run aarch64 kernel with Sabaton stivale2 on the raspi3 board",
    build_kernel(b, builtin.Arch.aarch64, "stivale2"),
  );

  qemu_run_aarch64_sabaton(b,
    "virt",
    "Run aarch64 kernel with Sabaton stivale2 on the virt board",
    build_kernel(b, builtin.Arch.aarch64, "stivale2"),
  );

  // qemu_run_riscv_sabaton(b,
  //   "riscv-virt",
  //   "(WIP) Run risc-v kernel with Sabaton stivale2 on the virt board",
  //   build_kernel(b, builtin.Arch.riscv64, "stivale2"),
  // );

  qloader_target(b,
    "x86_64-ql2",
    "Run x86_64 kernel with qloader2 stivale",
    b.fmt("{}/ql2.img", .{b.cache_root}),
    build_kernel(b, builtin.Arch.x86_64, "stivale"),
  );

  limine_target(b,
    "x86_64-limine",
    "Run x86_64 kernel with limine stivale2",
    b.fmt("{}/limine.img", .{b.cache_root}),
    build_kernel(b, builtin.Arch.x86_64, "stivale2"),
  );
}
