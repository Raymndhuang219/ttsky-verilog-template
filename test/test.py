# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

# Clock is 1 MHz (1 us period) matching the -GCLK_HZ=1000000 override in Makefile
CLK_PERIOD_US = 1
MS_CYCLES     = 1_000  # cycles per millisecond at 1 MHz

SEG_DASH  = 0b01000000  # "-"
SEG_BLANK = 0b00000000
SEG_G     = 0b01101111  # "G"
SEG_O     = 0b00111111  # "O"

SEG_DIGITS = {
    0b00111111: 0,
    0b00000110: 1,
    0b01011011: 2,
    0b01001111: 3,
    0b01100110: 4,
    0b01101101: 5,
    0b01111101: 6,
    0b00000111: 7,
    0b01111111: 8,
    0b01101111: 9,
}

async def do_reset(dut):
    dut.rst_n.value  = 0
    dut.ena.value    = 1
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value  = 1
    await ClockCycles(dut.clk, 10)


async def press_button(dut, hold=10):
    """Press and release ui_in[0]."""
    dut.ui_in.value = 0b00000001
    await ClockCycles(dut.clk, hold)
    dut.ui_in.value = 0b00000000
    await ClockCycles(dut.clk, 5)


async def wait_for_go(dut, timeout_cycles=10_000_000):
    """Poll until uo_out shows a GO-state segment pattern (G or O)."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        seg = int(dut.uo_out.value)
        if seg in (SEG_G, SEG_O):
            return True
    return False


async def read_display(dut, sample_cycles=5000):
    """
    Sample the multiplexed display and return (hundreds, tens, units).
    Returns None if any digit could not be decoded.
    """
    digits = {0b100: None, 0b010: None, 0b001: None}
    for _ in range(sample_cycles):
        await RisingEdge(dut.clk)
        sel = int(dut.uio_out.value) & 0b111
        seg = int(dut.uo_out.value)
        if sel in digits:
            d = SEG_DIGITS.get(seg)
            if d is not None:
                digits[sel] = d
    h = digits.get(0b100)
    t = digits.get(0b010)
    u = digits.get(0b001)
    if None in (h, t, u):
        return None
    return (h, t, u)

@cocotb.test()
async def test_idle_shows_dashes(dut):
    """After reset, display should show dashes on all digits."""
    dut._log.info("Start")
    clock = Clock(dut.clk, CLK_PERIOD_US, unit="us")
    cocotb.start_soon(clock.start())

    dut._log.info("Reset")
    await do_reset(dut)

    dut._log.info("Test project behavior")
    await ClockCycles(dut.clk, 100)

    seg = int(dut.uo_out.value)
    sel = int(dut.uio_out.value) & 0b111

    assert seg == SEG_DASH, f"Expected dash (0x40) in IDLE, got 0x{seg:02X}"
    assert sel == 0b111,    f"Expected all digit selects high in IDLE, got {sel:03b}"
    dut._log.info("PASS: IDLE shows dashes on all digits")


@cocotb.test()
async def test_early_press_resets(dut):
    """Pressing the button during WAITING should reset back to IDLE."""
    dut._log.info("Start")
    clock = Clock(dut.clk, CLK_PERIOD_US, unit="us")
    cocotb.start_soon(clock.start())

    dut._log.info("Reset")
    await do_reset(dut)

    dut._log.info("Test project behavior")
    await press_button(dut)        # start the game
    await ClockCycles(dut.clk, 50) # settle into WAITING state

    await press_button(dut)        # press too early
    await ClockCycles(dut.clk, 100)

    seg = int(dut.uo_out.value)
    assert seg == SEG_DASH, f"Expected IDLE (dashes) after early press, got 0x{seg:02X}"
    dut._log.info("PASS: Early press resets to IDLE")


@cocotb.test()
async def test_go_state_reached(dut):
    """After pressing start, the display should eventually show Go."""
    dut._log.info("Start")
    clock = Clock(dut.clk, CLK_PERIOD_US, unit="us")
    cocotb.start_soon(clock.start())

    dut._log.info("Reset")
    await do_reset(dut)

    dut._log.info("Test project behavior")
    await press_button(dut)

    # At 1 MHz, max wait is 5 seconds = 5,000,000 cycles, add some margin
    reached = await wait_for_go(dut, timeout_cycles=6_000_000)
    assert reached, "Timed out waiting for GO state"
    dut._log.info("PASS: GO state reached, display shows Go")


@cocotb.test()
async def test_reaction_time_displayed(dut):
    """React after a known number of ms and verify the display reads correctly."""
    dut._log.info("Start")
    clock = Clock(dut.clk, CLK_PERIOD_US, unit="us")
    cocotb.start_soon(clock.start())

    dut._log.info("Reset")
    await do_reset(dut)

    dut._log.info("Test project behavior")
    await press_button(dut)

    reached = await wait_for_go(dut, timeout_cycles=6_000_000)
    assert reached, "Timed out waiting for GO state"

    # Wait exactly 75 ms then press
    target_ms = 75
    await ClockCycles(dut.clk, target_ms * MS_CYCLES)
    await press_button(dut)
    await ClockCycles(dut.clk, 500)

    result = await read_display(dut)
    assert result is not None, "Could not decode display output — check segment wiring"

    displayed_ms = result[0] * 100 + result[1] * 10 + result[2]
    assert abs(displayed_ms - target_ms) <= 2, (
        f"Expected ~{target_ms}ms but got {displayed_ms}ms"
    )
    dut._log.info(f"PASS: Reaction time displayed correctly: {displayed_ms}ms (target {target_ms}ms)")


@cocotb.test()
async def test_result_press_returns_to_idle(dut):
    """After the result is shown, pressing the button should return to IDLE."""
    dut._log.info("Start")
    clock = Clock(dut.clk, CLK_PERIOD_US, unit="us")
    cocotb.start_soon(clock.start())

    dut._log.info("Reset")
    await do_reset(dut)

    dut._log.info("Test project behavior")
    await press_button(dut)

    reached = await wait_for_go(dut, timeout_cycles=6_000_000)
    assert reached, "Timed out waiting for GO state"

    await ClockCycles(dut.clk, 10 * MS_CYCLES)  # react after 10ms
    await press_button(dut)
    await ClockCycles(dut.clk, 500)

    await press_button(dut)  # press again to reset
    await ClockCycles(dut.clk, 100)

    seg = int(dut.uo_out.value)
    assert seg == SEG_DASH, f"Expected IDLE (dashes) after result reset, got 0x{seg:02X}"
    dut._log.info("PASS: Result press returns to IDLE")
