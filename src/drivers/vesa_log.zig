const os = @import("root").os;
const std = @import("std");

const range = os.lib.range.range;

const page_size = os.platform.page_sizes[0];

const paging = os.memory.paging;
const pmm    = os.memory.pmm;

// 8x8 bits per char
const char_width = 8;
const char_height = 8;

// '\x20' / ' ' (whitespace) is the first character in the font
const font_base = 0x20;
const font = @embedFile("vesa_font.bin");
const font_max_char: u8 = font_base + font.len/8;

const bgcol = 0x00;
const fgcol = 0xaa;

const clear_screen = false;

const Framebuffer = struct {
  addr: []u8,
  pitch: u64,
  width: u64,
  height: u64,
  bpp: u64,

  pos_x: u64 = 0,
  pos_y: u64 = 0,

  pub fn width_in_chars(self: *@This()) u64 {
    return self.width / char_width;
  }

  pub fn height_in_chars(self: *@This()) u64 {
    return self.height / char_height;
  }
};

var framebuffer: ?Framebuffer = null;

fn is_printable(c: u8) bool {
  return font_base <= c and c < font_max_char;
}

pub fn register_fb(fb_phys: usize, fb_pitch: u16, fb_width: u16, fb_height: u16, fb_bpp_in: u16) void {
  std.debug.assert(fb_bpp_in == 24 or fb_bpp_in == 32);
  // Bits are lies, I do bytes.
  const fb_bpp = fb_bpp_in / 8;
  const fb_size = @as(u64, fb_pitch) * @as(u64, fb_height);
  const fb_page_low = os.lib.libalign.align_down(usize, page_size, fb_phys);
  const fb_page_high = os.lib.libalign.align_up(usize, page_size, fb_phys + fb_size);

  paging.map_phys_range(fb_page_low, fb_page_high, paging.wc(paging.data()), null) catch |err| {
    os.log("VESAlog: Couldn't map fb: {}\n", .{@errorName(err)});
    return;
  };

  framebuffer = Framebuffer {
    .addr = pmm.access_phys(u8, fb_phys)[0..fb_size],
    .pitch = fb_pitch,
    .width = fb_width,
    .height = fb_height,
    .bpp = fb_bpp,
  };

  if(clear_screen) {
    @memset(@ptrCast([*]u8, framebuffer.?.addr), bgcol, fb_size);
    os.log("VESAlog: Screen cleared.\n", .{});
  }

  os.log("VESAlog: Registered fb @0x{X} with size 0x{X}\n", .{fb_phys, fb_size});
  os.log("VESAlog:  Width:  {}\n", .{fb_width});
  os.log("VESAlog:  Height: {}\n", .{fb_height});
  os.log("VESAlog:  Pitch:  {}\n", .{fb_pitch});
  os.log("VESAlog:  BPP:    {}\n", .{fb_bpp});
}

fn px(comptime bpp: u64, x: u64, y: u64) *[3]u8 {
  const offset = framebuffer.?.pitch * y + x * bpp;
  return framebuffer.?.addr[offset .. offset + 3][0..3];
}

fn blit_impl(comptime bpp: u64, ch: u8) void {
  inline for(range(char_height)) |y| {
    const chr_line = font[y + (@as(u64, ch) - font_base) * char_height * ((char_width + 7)/8)];

    const ypx = framebuffer.?.pos_y * char_height + y;

    inline for(range(char_width)) |x| {
      const xpx = framebuffer.?.pos_x * char_width + x;

      const pixel = px(bpp, xpx, ypx);

      const shift: u3 = char_width - 1 - x;
      const has_pixel_set = ((chr_line >> shift) & 1) == 1;

      if(has_pixel_set) {
        pixel[0] = fgcol;
        pixel[1] = fgcol;
        pixel[2] = fgcol;
      }
      else {
        pixel[0] = bgcol;
        pixel[1] = bgcol;
        pixel[2] = bgcol;
      }
    }
  }
  framebuffer.?.pos_x += 1;
}

fn blit_char(ch: u8) void {
  if(framebuffer.?.bpp == 4) {
    blit_impl(4, ch);
    return;
  }
  if(framebuffer.?.bpp == 3) {
    blit_impl(3, ch);
    return;
  }
  unreachable;
}

fn scroll_fb() void {
  // Speeds this up by like 8x, and I don't think there are bugs here
  @setRuntimeSafety(false);

  // Yes this is slow but I don't care, I love it.
  var y: u64 = char_height;
  while(y < (framebuffer.?.height/char_height) * char_height): (y += 1) {
    const dst = @ptrCast([*]u8, framebuffer.?.addr) + framebuffer.?.pitch * (y - char_height);
    const src = @ptrCast([*]u8, framebuffer.?.addr) + framebuffer.?.pitch * y;
    @memcpy(dst, src, framebuffer.?.pitch);
  }
  @memset(@ptrCast([*]u8, framebuffer.?.addr) + framebuffer.?.pitch * (y - char_height), 0x00, framebuffer.?.pitch * char_height);
}

fn feed_line() void {
  framebuffer.?.pos_x = 0;
  if(framebuffer.?.pos_y == framebuffer.?.height_in_chars() - 1) {
    scroll_fb();
  }
  else {
    framebuffer.?.pos_y += 1;
  }
}

pub fn putch(ch: u8) void {
  if(framebuffer != null) {
    if(ch == '\n') {
      feed_line();
      return;
    }

    if(framebuffer.?.pos_x == framebuffer.?.width_in_chars())
      feed_line();

    if(!is_printable(ch)) {
      std.debug.assert(is_printable('?'));
      blit_char('?');
    }
    else {
      blit_char(ch);
    }
  }
}

pub fn disable() void {
  framebuffer = null;
}
