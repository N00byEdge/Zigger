const os = @import("root").os;
const assert = @import("std").debug.assert;

const interrupts = @import("interrupts.zig");
const gdt = @import("gdt.zig");

const num_handlers = interrupts.num_handlers;

const Idtr = packed struct {
  limit: u16,
  addr: u64,
};

var idt = [1]idt_entry{undefined} ** num_handlers;

pub const InterruptHandler = fn func() callconv(.Naked) void;

pub fn setup_idt() *[num_handlers]idt_entry {
  os.log("IDT: Setting up IDT...\n", .{});

  const idtr = Idtr {
    .addr = @ptrToInt(&idt[0]),
    .limit = @sizeOf(@TypeOf(idt)) - 1,
  };

  asm volatile(
    \\  lidt (%[idtr_addr])
    :
    : [idtr_addr] "r" (&idtr)
  );

  return idt[0..];
}

pub fn entry(handler: InterruptHandler, interrupt: bool, priv_level: u2) idt_entry {
  return encode(
    @ptrToInt(handler), // addr
    0, // ist
    if (interrupt) 0xE else 0xF, // gate_type
    0, // storage
    priv_level, // priv_level
    1, // present
  );
}

const idt_entry = packed struct {
  addr_low: u16,
  selector: u16,
  ist: u8,
  gate_type: u4,
  storage: u1,
  priv_level: u2,
  present: u1,
  addr_mid: u16,
  addr_high: u32,
  zeroes: u32 = 0,
};

pub fn encode(addr: u64, ist: u8, gate_type: u4, storage: u1, priv_level: u2, present: u1) idt_entry {
  return idt_entry {
    .addr_low = @intCast(u16, addr & 0xFFFF),
    .addr_mid = @intCast(u16, (addr >> 16) & 0xFFFF),
    .addr_high = @intCast(u32, (addr >> 32) & 0xFFFFFFFF),
    .selector = gdt.selector.code64 | priv_level,
    .ist = ist,
    .gate_type = gate_type,
    .storage = storage,
    .priv_level = priv_level,
    .present = present,
  };
}

comptime {
  assert(@sizeOf(idt_entry) == 16);
}
