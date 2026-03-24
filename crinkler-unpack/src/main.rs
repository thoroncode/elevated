//! crinkler-unpack — standalone Crinkler decompressor for elevated.exe
//!
//! Key observations from tracing:
//!   • Crinkler writes output BACKWARDS from 0x41FFFF toward lower addresses.
//!   • 0x4000bc is reached once per byte of compressed input (outer bit loop),
//!     NOT only at the true "done" condition.
//!   • The sentinel branch "je 0x4000bc" is at 0x40008E.
//!     It fires when `lodsd EAX, [esi]; add EAX, EDI == 0`.
//!   • After that branch fires, execution falls into Windows import resolution
//!     which loops forever in our emulator.
//!
//! Strategy: hook 0x40008E, detect when the sentinel is about to trigger
//! (EAX+EDI == 0), and stop immediately.

use std::cell::RefCell;
use std::env;
use std::fs;
use std::rc::Rc;

use unicorn_engine::unicorn_const::{Arch, HookType, Mode, Prot, SECOND_SCALE};
use unicorn_engine::{RegisterX86, Unicorn};

const MEM_BASE:  u64   = 0x0040_0000;
const MEM_SIZE:  usize = 0x0040_0000; // 4 MB
const STACK_TOP: u64   = 0x00C0_0000;
const STACK_SZ:  usize = 0x0001_0000;

const ENTRY:     u64 = 0x40005C; // radare2 entry0
// The "add eax, edi; je 0x4000bc" is at 0x40008c-0x40008e.
// We hook 0x40008c (the ADD instruction) to catch when the result is zero.
const ADD_INSN:  u64 = 0x40008C;

fn main() {
    let args: Vec<String> = env::args().collect();
    let exe_path = args.get(1).map(|s| s.as_str()).unwrap_or("elevated_1920_1080.exe");
    let out_path = args.get(2).map(|s| s.as_str()).unwrap_or("elevated_unpacked.bin");

    let raw = fs::read(exe_path).expect("cannot read input file");
    println!("Input:  {}  ({} bytes)", exe_path, raw.len());

    let mut emu = Unicorn::new(Arch::X86, Mode::MODE_32).expect("Unicorn init failed");

    emu.mem_map(MEM_BASE, MEM_SIZE as u64, Prot::ALL).unwrap();
    emu.mem_map(STACK_TOP - STACK_SZ as u64, STACK_SZ as u64, Prot::ALL).unwrap();

    let mut img = raw.clone();
    img.resize(MEM_SIZE, 0);
    emu.mem_write(MEM_BASE, &img).unwrap();
    emu.reg_write(RegisterX86::ESP as i32, STACK_TOP - 16).unwrap();

    // Lazy-map stray page faults
    emu.add_mem_hook(HookType::MEM_UNMAPPED, 0, u64::MAX, |uc, _t, addr, _sz, _v| {
        let page = addr & !0xFFF;
        let _ = uc.mem_map(page, 0x1000, Prot::ALL);
        let _ = uc.mem_write(page, &vec![0u8; 0x1000]);
        true
    }).unwrap();

    // ── Hook the ADD EAX,EDI instruction ─────────────────────────
    // This fires once per outer loop iteration. When EAX+EDI would be 0
    // (the sentinel), we stop — all output bytes have been written.
    let done: Rc<RefCell<bool>> = Rc::new(RefCell::new(false));
    let done2 = Rc::clone(&done);

    emu.add_code_hook(ADD_INSN, ADD_INSN + 1, move |uc, _addr, _size| {
        let eax = uc.reg_read(RegisterX86::EAX as i32).unwrap_or(1) as u32;
        let edi = uc.reg_read(RegisterX86::EDI as i32).unwrap_or(1) as u32;
        if eax.wrapping_add(edi) == 0 {
            eprintln!("  [done] sentinel: EAX=0x{eax:08x} EDI=0x{edi:08x} -> EAX+EDI=0");
            *done2.borrow_mut() = true;
            uc.emu_stop().unwrap();
        }
    }).unwrap();

    // ── Run ───────────────────────────────────────────────────────
    println!("Emulating from 0x{ENTRY:08x} …");
    let t0 = std::time::Instant::now();

    let _ = emu.emu_start(ENTRY, MEM_BASE + MEM_SIZE as u64, 300 * SECOND_SCALE, 0);

    let eip = emu.reg_read(RegisterX86::EIP as i32).unwrap_or(0);
    let edi = emu.reg_read(RegisterX86::EDI as i32).unwrap_or(0);
    let esi = emu.reg_read(RegisterX86::ESI as i32).unwrap_or(0);
    eprintln!("  done in {:.2?}  EIP=0x{eip:08x}  EDI=0x{edi:08x}  ESI=0x{esi:08x}",
              t0.elapsed());

    if !*done.borrow() {
        eprintln!("  WARNING: sentinel never detected — output may be incomplete");
    }

    // ── Read back full memory ─────────────────────────────────────
    let mut mem = vec![0u8; MEM_SIZE];
    emu.mem_read(MEM_BASE, &mut mem).unwrap();

    // Output was written backward from 0x41FFFF; EDI is the lowest address written.
    let out_lo = if edi >= MEM_BASE && edi < MEM_BASE + 0x20000 {
        (edi - MEM_BASE) as usize
    } else {
        0
    };
    let out_hi = (0x4200_0000u64 - MEM_BASE).min(MEM_SIZE as u64) as usize;
    // Sanity: also include a broader region in case our estimate is off
    let scan_lo = out_lo.saturating_sub(0x2000);
    let decompressed = &mem[scan_lo..out_hi];

    println!("  EDI=0x{edi:08x} → scanning 0x{:08x}–0x{:08x}  ({} bytes)",
             MEM_BASE as usize + scan_lo,
             MEM_BASE as usize + out_hi,
             decompressed.len());

    // ── Search for text strings ───────────────────────────────────
    println!("Scanning for text strings >= 30 chars …");
    let mut found = 0usize;
    let mut i = 0usize;
    while i < decompressed.len() {
        let start = i;
        while i < decompressed.len() && decompressed[i] >= 0x20 && decompressed[i] < 0x7f {
            i += 1;
        }
        let len = i - start;
        if len >= 30 {
            let va = MEM_BASE as usize + scan_lo + start;
            let s = std::str::from_utf8(&decompressed[start..start+len]).unwrap_or("?");
            println!("  @0x{va:08x} [{len:4}]: {}", &s[..len.min(120)]);
            found += 1;
        }
        i += 1;
    }
    println!("  Found {found} text strings");

    // ── Save ──────────────────────────────────────────────────────
    fs::write(out_path, decompressed).expect("write failed");
    println!("Saved → {}  ({} bytes)", out_path, decompressed.len());
}
