// pi extension for `sift auto` topic sweeps. the weak local model tends to
// batch its write-up to the end of a session, so when the wall-clock
// deadline (or pi's lossy auto-compaction) cuts in, everything it learned
// is gone and the topic leaves no segment. the trigger here is context
// pressure, not time: as the conversation fills the model's window — i.e.
// as its room to think runs out — steer in a reminder to flush every
// un-recorded finding to `sift note` before it does anything else. fires
// once per band (default 60% and 85% of the context window); override with
// SIFT_NOTE_NUDGE="50,75,90".
export default function (pi: any) {
    const bands = (process.env.SIFT_NOTE_NUDGE ?? "60,85")
        .split(",").map(Number).filter((n) => n > 0 && n <= 100).sort((a, b) => a - b);
    let fired = 0;
    pi.on("turn_end", async (_event: any, ctx: any) => {
        const pct = ctx.getContextUsage?.()?.percent;
        if (pct == null) return;
        while (fired < bands.length && pct >= bands[fired]) {
            fired++;
            pi.sendUserMessage(
                `Context is ${Math.round(pct)}% full — your room to think is running out. `
                + `Before any more searches or reads, write up every finding you haven't `
                + `recorded yet: one \`sift note "…"\` call per fact, citing its source `
                + `alias (\`r4\`). Anything left only in this conversation is lost when the `
                + `session ends. Then carry on if there's room, or stop.`,
                { deliverAs: "steer" },
            );
        }
    });
}
