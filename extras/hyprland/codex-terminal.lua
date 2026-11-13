-- Dedicated persistent Codex dropdown. Separate from SUPER+` / special:term.
hl.window_rule({
    name = "codex-dropterm",
    match = { class = "^codex-dropterm$" },
    workspace = "special:codex silent",
    float = true,
    size = "monitor_w*0.7 monitor_h*0.5",
    move = "monitor_w*0.15 50",
    dim_around = true,
})
