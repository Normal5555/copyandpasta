-- ═══════════════════════════════════════════════════════════════════════════
--  AMONG US — BOMBA MOD MENU v2
--  dump  : Assembly-CSharp.dll
--  api   : BOMBA Lua
--
--  NEW  ── Overload tab
--           Hooks RpcSendQuickChat to capture a live QuickChatPhraseBuilderResult*
--           on first legitimate send, then floods every FixedUpdate frame with
--           N rapid RpcSendQuickChat calls — saturates receiver RPC queues.
--
--  Tabs : [Player] [Impostor] [Overload] [Stealth]
--
--  All hooks carry the trailing MethodInfo* ptr (ARM IL2CPP ABI fix).
--  All null guards use isNull() which covers both Lua nil and raw 0x0.
--  Hook bodies are pcall-wrapped; DrawImGui is pcall-wrapped with guaranteed
--  style-stack balance.
-- ═══════════════════════════════════════════════════════════════════════════


-- ── STATE ────────────────────────────────────────────────────────────────────

local state = {
    -- Player
    speedHack     = false,
    speedVal      = 5.0,
    ghostSpeedVal = 3.0,
    ventAnywhere  = false,

    -- Impostor
    killFreeze    = false,
    alwaysKill    = false,
    forceRoleIdx  = 2,

    -- Overload
    overload      = false,
    floodRate     = 20,      -- RpcSendQuickChat calls per FixedUpdate frame
    capturedQC    = nil,     -- QuickChatPhraseBuilderResult* — captured on first natural send
    floodsFired   = 0,       -- lifetime counter

    -- Stealth
    godMode       = false,
    invisible     = false,
    nameInput     = "BOMBA",
}

local status = { text = "waiting...", color = {0.5, 0.5, 0.5, 1.0} }


-- ── ROLE TABLE ───────────────────────────────────────────────────────────────

local ROLES = {
    { label = "Crewmate",      id = 0  },
    { label = "Impostor",      id = 1  },
    { label = "Scientist",     id = 2  },
    { label = "Engineer",      id = 3  },
    { label = "GuardianAngel", id = 4  },
    { label = "Shapeshifter",  id = 5  },
    { label = "Noisemaker",    id = 8  },
    { label = "Phantom",       id = 9  },
    { label = "Tracker",       id = 10 },
    { label = "Detective",     id = 12 },
    { label = "Viper",         id = 18 },
    { label = "Judge",         id = 19 },
}

local roleLabels = {}
for _, r in ipairs(ROLES) do table.insert(roleLabels, r.label) end

local function roleNameForId(id)
    for _, r in ipairs(ROLES) do
        if r.id == id then return r.label end
    end
    return string.format("?(id=%i)", id)
end


-- ── OFFSETS ───────────────────────────────────────────────────────────────────

local PC = {
    moveable           = 0x4C,
    ForceKillTimerCont = 0x58,
    inVent             = 0x60,
    invisibilityAlpha  = 0x6C,
    CachedPlayerData   = 0x70,
    shouldAppearInvis  = 0x84,
    killTimer          = 0xB0,
    MyPhysics          = 0xD0,
}

local PHYS = {
    Speed      = 0x50,
    GhostSpeed = 0x54,
    myPlayer   = 0x68,
}

local NPI = {
    RoleType = 0x50,
    IsDead   = 0x78,
}

-- Il2Cpp List<T> internal layout
local LIST = {
    items = 0x10,  -- T[] _items  (ptr to Il2CppArray)
    size  = 0x18,  -- int _size
}

-- Il2CppArray items start after the 0x20-byte array header
local ARRAY_DATA_OFFSET = 0x20


-- ── CLASS RESOLUTION ─────────────────────────────────────────────────────────

local cls_PC   = BOMBA.Class("", "PlayerControl")
local cls_PHYS = BOMBA.Class("", "PlayerPhysics")

LOGD("[BOMBA v2] cls_PC=%s  cls_PHYS=%s", tostring(cls_PC), tostring(cls_PHYS))

local fld_LocalPlayer    = cls_PC:GetField("LocalPlayer"):cast("ptr")
local fld_AllPlayers     = cls_PC:GetField("AllPlayerControls"):cast("ptr")

LOGD("[BOMBA v2] fields resolved: LocalPlayer=%s  AllPlayerControls=%s",
    tostring(fld_LocalPlayer), tostring(fld_AllPlayers))


-- ── HELPERS ───────────────────────────────────────────────────────────────────

local function isNull(p) return not p or p == 0 end

local function localPlayer()
    local lp = fld_LocalPlayer:GetStatic()
    return isNull(lp) and nil or lp
end

local function getPhysics(lp)
    if isNull(lp) then return nil end
    local p = BOMBA.read_ptr(lp, PC.MyPhysics)
    return isNull(p) and nil or p
end

local function getData(lp)
    if isNull(lp) then return nil end
    local d = BOMBA.read_ptr(lp, PC.CachedPlayerData)
    return isNull(d) and nil or d
end

-- Iterate AllPlayerControls list, returns array of PlayerControl ptrs
local function getAllPlayers()
    local list = fld_AllPlayers:GetStatic()
    if isNull(list) then return {} end
    local items = BOMBA.read_ptr(list, LIST.items)
    if isNull(items) then return {} end
    local count = BOMBA.read_int(list, LIST.size)
    if count <= 0 then return {} end
    local out = {}
    for i = 0, count - 1 do
        local ptr = BOMBA.read_ptr(items, ARRAY_DATA_OFFSET + i * 8)
        if not isNull(ptr) then
            table.insert(out, ptr)
        end
    end
    return out
end


-- ── LAZY METHOD CACHE ─────────────────────────────────────────────────────────
-- Methods resolved on first use so they don't crash at script load time.

local _fn_QC   = nil  -- RpcSendQuickChat
local _fn_name = nil  -- SetName
local _fn_role = nil  -- RpcSetRole

local function fnQC()
    if not _fn_QC then
        _fn_QC = cls_PC:GetMethod("RpcSendQuickChat", 1)
            :cast({ ret = "bool", args = {"ptr", "ptr"} })
        LOGD("[BOMBA v2] RpcSendQuickChat resolved")
    end
    return _fn_QC
end

local function fnName()
    if not _fn_name then
        _fn_name = cls_PC:GetMethod("SetName", 1)
            :cast({ ret = "void", args = {"ptr", "string"} })
    end
    return _fn_name
end

local function fnRole()
    if not _fn_role then
        _fn_role = cls_PC:GetMethod("RpcSetRole", 2)
            :cast({ ret = "void", args = {"ptr", "ushort", "bool"} })
    end
    return _fn_role
end


-- ── HOOK 1 — PlayerPhysics.FixedUpdate ───────────────────────────────────────
--  Handles: speed hack, kill timer freeze, vent anywhere, invisibility, OVERLOAD.

local function _physicsUpdate(physInst)
    local lp = localPlayer()
    if not lp then return end

    local myPCPtr = BOMBA.read_ptr(physInst, PHYS.myPlayer)
    if isNull(myPCPtr) or myPCPtr ~= lp then return end

    -- speed hack
    if state.speedHack then
        BOMBA.write_float(physInst, PHYS.Speed,      state.speedVal)
        BOMBA.write_float(physInst, PHYS.GhostSpeed, state.ghostSpeedVal)
    end

    -- kill timer freeze
    if state.killFreeze then
        BOMBA.write_float(lp, PC.killTimer,           0.0)
        BOMBA.write_bool(lp,  PC.ForceKillTimerCont,  true)
    end

    -- vent anywhere
    if state.ventAnywhere then
        BOMBA.write_bool(lp, PC.inVent,   true)
        BOMBA.write_bool(lp, PC.moveable, true)
    end

    -- invisibility
    if state.invisible then
        BOMBA.write_float(lp, PC.invisibilityAlpha, 0.0)
        BOMBA.write_bool(lp,  PC.shouldAppearInvis, true)
    end

    -- ─── OVERLOAD ─────────────────────────────────────────────────────────
    -- Fires floodRate RpcSendQuickChat RPCs per frame.
    -- capturedQC must be set first by sending any QuickChat legitimately.
    -- pcall guards against stale ptr if GC collects the data object;
    -- on first error we clear the cache and stop until user re-arms.
    if state.overload and not isNull(state.capturedQC) then
        local fn = fnQC()
        if fn then
            for i = 1, state.floodRate do
                local ok, err = pcall(fn.Call, fn, lp, state.capturedQC)
                if not ok then
                    LOGD("[BOMBA v2] flood: ptr went stale — clearing. err: %s", tostring(err))
                    state.capturedQC = nil
                    state.overload   = false
                    break
                end
                state.floodsFired = state.floodsFired + 1
            end
        end
    end
end

function OnPhysicsFixedUpdate(physInst, mi)
    local ok, err = pcall(_physicsUpdate, physInst)
    if not ok then LOGD("[BOMBA v2] FixedUpdate ERR: %s", tostring(err)) end
    return BOMBA.call_original(physInst, mi)
end

BOMBA.HOOK(
    cls_PHYS:GetMethod("FixedUpdate", 0),
    { ret = "void", args = {"ptr", "ptr"} },
    OnPhysicsFixedUpdate
)
LOGD("[BOMBA v2] hook 1: PlayerPhysics.FixedUpdate")


-- ── HOOK 2 — PlayerControl.RpcSendQuickChat ──────────────────────────────────
--  Captures the QuickChatPhraseBuilderResult* on the first legitimate send.
--  The data object is a normal managed allocation — we cache its raw ptr.
--  The overload reuses this ptr to replay the packet at high frequency.
--
--  Signature: bool RpcSendQuickChat(QuickChatPhraseBuilderResult data)
--  IL2CPP ABI (ARM): (PlayerControl* self, QuickChatPhraseBuilderResult* data, MethodInfo* mi)

function OnRpcSendQuickChat(self, data, mi)
    -- capture on every legitimate send so the cache stays fresh
    if not isNull(data) then
        state.capturedQC = data
        LOGD("[BOMBA v2] QuickChat capture refreshed @ %p", data)
    end
    return BOMBA.call_original(self, data, mi)
end

BOMBA.HOOK(
    cls_PC:GetMethod("RpcSendQuickChat", 1),
    { ret = "bool", args = {"ptr", "ptr", "ptr"} },
    OnRpcSendQuickChat
)
LOGD("[BOMBA v2] hook 2: PlayerControl.RpcSendQuickChat (capture)")


-- ── HOOK 3 — PlayerControl.get_IsKillTimerEnabled ────────────────────────────

function OnIsKillTimerEnabled(pcInst, mi)
    if state.alwaysKill then return true end
    return BOMBA.call_original(pcInst, mi)
end

BOMBA.HOOK(
    cls_PC:GetMethod("get_IsKillTimerEnabled", 0),
    { ret = "bool", args = {"ptr", "ptr"} },
    OnIsKillTimerEnabled
)
LOGD("[BOMBA v2] hook 3: get_IsKillTimerEnabled")


-- ── HOOK 4 — PlayerControl.Die ───────────────────────────────────────────────

local function _die(pcInst, reason, assignGhostRole)
    return state.godMode
end

function OnDie(pcInst, reason, assignGhostRole, mi)
    local ok, skip = pcall(_die, pcInst, reason, assignGhostRole)
    if not ok then skip = false end
    if skip then return end
    return BOMBA.call_original(pcInst, reason, assignGhostRole, mi)
end

BOMBA.HOOK(
    cls_PC:GetMethod("Die", 2),
    { ret = "void", args = {"ptr", "int", "bool", "ptr"} },
    OnDie
)
LOGD("[BOMBA v2] hook 4: Die")


-- ── ACTIONS ───────────────────────────────────────────────────────────────────

local function doForceRole()
    local lp = localPlayer()
    if not lp then
        status.text  = "Not in game"
        status.color = {1.0, 0.5, 0.0, 1.0}
        return
    end
    local roleId = ROLES[state.forceRoleIdx].id
    local ok, err = pcall(fnRole().Call, fnRole(), lp, roleId, true)
    if ok then
        status.text  = string.format("Role → %s (id=%i)", ROLES[state.forceRoleIdx].label, roleId)
        status.color = {0.3, 1.0, 0.4, 1.0}
    else
        status.text  = "RpcSetRole failed"
        status.color = {1.0, 0.2, 0.2, 1.0}
        LOGD("[BOMBA v2] RpcSetRole ERR: %s", tostring(err))
    end
end

local function doSetName()
    local lp = localPlayer()
    if not lp then
        status.text  = "Not in game"
        status.color = {1.0, 0.5, 0.0, 1.0}
        return
    end
    local ok, err = pcall(fnName().Call, fnName(), lp, state.nameInput)
    if ok then
        status.text  = string.format('Name → "%s"', state.nameInput)
        status.color = {0.5, 0.8, 1.0, 1.0}
    else
        LOGD("[BOMBA v2] SetName ERR: %s", tostring(err))
    end
end

local function doResetSpeed()
    local lp = localPlayer()
    if not lp then return end
    local phys = getPhysics(lp)
    if not phys then return end
    BOMBA.write_float(phys, PHYS.Speed,      2.5)
    BOMBA.write_float(phys, PHYS.GhostSpeed, 1.5)
    state.speedHack = false
    status.text  = "Speed reset"
    status.color = {0.7, 0.7, 0.7, 1.0}
end


-- ── STATUS POLL ───────────────────────────────────────────────────────────────

local _tick = 0

local function pollStatus()
    _tick = _tick + 1
    if _tick % 45 ~= 0 then return end

    local lp = localPlayer()
    if not lp then
        status.text  = "Not in game"
        status.color = {0.5, 0.5, 0.5, 1.0}
        return
    end

    local roleId = -1
    local spd    = 0.0

    local data = getData(lp)
    if data then roleId = BOMBA.read_int(data, NPI.RoleType) end

    local phys = getPhysics(lp)
    if phys then spd = BOMBA.read_float(phys, PHYS.Speed) end

    local isImp = (roleId == 1 or roleId == 5 or roleId == 7
                or roleId == 9 or roleId == 18 or roleId == 19)

    status.text  = string.format("Role: %s   Speed: %.1f", roleNameForId(roleId), spd)
    status.color = isImp and {1.0, 0.25, 0.25, 1.0} or {0.45, 0.85, 0.55, 1.0}
end


-- ── THEME ─────────────────────────────────────────────────────────────────────

local CLR = {
    bg      = {0.07, 0.03, 0.11, 0.97},
    frame   = {0.16, 0.09, 0.24, 1.0},
    btn     = {0.42, 0.07, 0.74, 1.0},
    btn_h   = {0.56, 0.18, 0.88, 1.0},
    btn_a   = {0.66, 0.28, 0.98, 1.0},
    red     = {0.82, 0.08, 0.08, 1.0},
    red_h   = {0.98, 0.18, 0.18, 1.0},
    red_a   = {1.00, 0.38, 0.38, 1.0},
    armed   = {0.18, 0.88, 0.32, 1.0},
    warn    = {0.95, 0.62, 0.08, 1.0},
    dim     = {0.40, 0.40, 0.50, 1.0},
}


-- ── IMGUI ─────────────────────────────────────────────────────────────────────

local function innerDraw(width, height)
    pollStatus()

    ImGui.SetNextWindowSize({500, 460}, ImGui.Cond_Once)
    ImGui.SetNextWindowPos({24, 50},   ImGui.Cond_Once)

    if ImGui.Begin("  \240\159\148\173 BOMBA v2  //  Among Us", ImGui.WindowFlags_NoCollapse) then

        -- top status bar
        ImGui.PushStyleColor(ImGui.Col_Text, status.color)
        ImGui.Text(status.text)
        ImGui.PopStyleColor()
        ImGui.Separator()
        ImGui.Spacing()

        if ImGui.BeginTabBar("main_tabs") then

            -- ────────────────────────────────────────────────────────────────
            -- TAB : PLAYER
            -- ────────────────────────────────────────────────────────────────
            if ImGui.BeginTabItem("  Player  ") then
                ImGui.Spacing()
                state.speedHack, _ = ImGui.Checkbox("Speed Hack", state.speedHack)
                ImGui.Spacing()

                ImGui.PushItemWidth(290)
                state.speedVal, _ = ImGui.SliderFloat(
                    "Move Speed", state.speedVal, 0.5, 20.0, "%.1f u/s")
                state.ghostSpeedVal, _ = ImGui.SliderFloat(
                    "Ghost Speed", state.ghostSpeedVal, 0.5, 20.0, "%.1f u/s")
                ImGui.PopItemWidth()

                ImGui.Spacing()
                ImGui.PushStyleColor(ImGui.Col_Button,        CLR.btn)
                ImGui.PushStyleColor(ImGui.Col_ButtonHovered, CLR.btn_h)
                ImGui.PushStyleColor(ImGui.Col_ButtonActive,  CLR.btn_a)
                if ImGui.Button("Reset Speed", {130, 30}) then doResetSpeed() end
                ImGui.PopStyleColor(3)

                ImGui.Spacing()
                ImGui.Separator()
                ImGui.Spacing()
                state.ventAnywhere, _ = ImGui.Checkbox(
                    "Vent Anywhere  (inVent + moveable forced true)", state.ventAnywhere)

                ImGui.EndTabItem()
            end

            -- ────────────────────────────────────────────────────────────────
            -- TAB : IMPOSTOR
            -- ────────────────────────────────────────────────────────────────
            if ImGui.BeginTabItem("  Impostor  ") then
                ImGui.Spacing()
                state.killFreeze, _ = ImGui.Checkbox(
                    "Kill Timer Freeze  (killTimer  0, ForceKillTimerContinue  true)",
                    state.killFreeze)
                ImGui.Spacing()
                state.alwaysKill, _ = ImGui.Checkbox(
                    "Always Can Kill  (IsKillTimerEnabled hook  true)",
                    state.alwaysKill)

                ImGui.Spacing()
                ImGui.Separator()
                ImGui.Spacing()
                ImGui.Text("Force Role  (RpcSetRole — server-side broadcast)")
                ImGui.Spacing()

                ImGui.PushItemWidth(240)
                state.forceRoleIdx, _ = ImGui.Combo("##role", state.forceRoleIdx, roleLabels)
                ImGui.PopItemWidth()
                ImGui.SameLine()

                ImGui.PushStyleColor(ImGui.Col_Button,        CLR.btn)
                ImGui.PushStyleColor(ImGui.Col_ButtonHovered, CLR.btn_h)
                ImGui.PushStyleColor(ImGui.Col_ButtonActive,  CLR.btn_a)
                if ImGui.Button("Apply##r", {90, 26}) then doForceRole() end
                ImGui.PopStyleColor(3)

                ImGui.Spacing()
                ImGui.PushStyleColor(ImGui.Col_Text, CLR.dim)
                ImGui.Text(string.format("RoleTypes.%s = id %i",
                    ROLES[state.forceRoleIdx].label,
                    ROLES[state.forceRoleIdx].id))
                ImGui.PopStyleColor()

                ImGui.EndTabItem()
            end

            -- ────────────────────────────────────────────────────────────────
            -- TAB : OVERLOAD
            -- ────────────────────────────────────────────────────────────────
            if ImGui.BeginTabItem("  Overload  ") then
                ImGui.Spacing()

                -- ── Capture status indicator ──────────────────────────────
                local isArmed = not isNull(state.capturedQC)
                if isArmed then
                    ImGui.PushStyleColor(ImGui.Col_Text, CLR.armed)
                    ImGui.Text(string.format(
                        "\226\151\143 ARMED   QuickChatPhraseBuilderResult @ %p",
                        state.capturedQC))
                    ImGui.PopStyleColor()
                else
                    ImGui.PushStyleColor(ImGui.Col_Text, CLR.warn)
                    ImGui.Text("\226\151\139 WAITING   Send one QuickChat in-game to arm")
                    ImGui.PopStyleColor()
                end

                ImGui.Spacing()
                ImGui.Separator()
                ImGui.Spacing()

                -- ── Main OVERLOAD toggle button ───────────────────────────
                -- Switches between danger-red (active) and purple (inactive).
                -- Disabled visually when not armed.
                if state.overload then
                    ImGui.PushStyleColor(ImGui.Col_Button,        CLR.red)
                    ImGui.PushStyleColor(ImGui.Col_ButtonHovered, CLR.red_h)
                    ImGui.PushStyleColor(ImGui.Col_ButtonActive,  CLR.red_a)
                    if ImGui.Button("\226\150\160 OVERLOAD ACTIVE  \226\128\148  TAP TO STOP", {460, 48}) then
                        state.overload = false
                    end
                    ImGui.PopStyleColor(3)
                else
                    if isArmed then
                        ImGui.PushStyleColor(ImGui.Col_Button,        CLR.btn)
                        ImGui.PushStyleColor(ImGui.Col_ButtonHovered, CLR.btn_h)
                        ImGui.PushStyleColor(ImGui.Col_ButtonActive,  CLR.btn_a)
                    else
                        -- greyed out when not armed
                        ImGui.PushStyleColor(ImGui.Col_Button,        {0.25, 0.25, 0.30, 1.0})
                        ImGui.PushStyleColor(ImGui.Col_ButtonHovered, {0.25, 0.25, 0.30, 1.0})
                        ImGui.PushStyleColor(ImGui.Col_ButtonActive,  {0.25, 0.25, 0.30, 1.0})
                    end
                    if ImGui.Button("\226\150\176 START OVERLOAD", {460, 48}) then
                        if isArmed then state.overload = true end
                    end
                    ImGui.PopStyleColor(3)
                end

                ImGui.Spacing()
                ImGui.Separator()
                ImGui.Spacing()

                -- ── Flood rate slider ─────────────────────────────────────
                -- "Moveable" control LO asked for: how many RPCs per frame.
                -- 1 frame  = 1 FixedUpdate tick (~50-60 Hz on mobile).
                -- 20/frame = ~1000 RPC/sec  → crash in ~1-2 s
                -- 50/frame = ~2500 RPC/sec  → crash in <1 s
                -- 100/frame = ~5000 RPC/sec → near-instant, risks local lag
                ImGui.Text("Flood Rate  (RpcSendQuickChat calls per frame)")
                ImGui.Spacing()

                ImGui.PushItemWidth(380)
                state.floodRate, _ = ImGui.SliderInt(
                    "##rate", state.floodRate, 1, 100)
                ImGui.PopItemWidth()
                ImGui.SameLine()
                ImGui.PushStyleColor(ImGui.Col_Text,
                    state.floodRate >= 50 and CLR.red or
                    state.floodRate >= 25 and CLR.warn or
                    CLR.armed)
                ImGui.Text(string.format("%i / frame", state.floodRate))
                ImGui.PopStyleColor()

                -- estimated RPC/s label
                ImGui.PushStyleColor(ImGui.Col_Text, CLR.dim)
                ImGui.Text(string.format(
                    "~%i RPC/sec at 50 Hz FixedUpdate", state.floodRate * 50))
                ImGui.PopStyleColor()

                ImGui.Spacing()
                ImGui.Separator()
                ImGui.Spacing()

                -- ── Counters ──────────────────────────────────────────────
                ImGui.Text(string.format("RPCs fired this session:  %i", state.floodsFired))

                ImGui.Spacing()
                ImGui.PushStyleColor(ImGui.Col_Button,        CLR.btn)
                ImGui.PushStyleColor(ImGui.Col_ButtonHovered, CLR.btn_h)
                ImGui.PushStyleColor(ImGui.Col_ButtonActive,  CLR.btn_a)
                if ImGui.Button("Clear Capture##ov", {140, 28}) then
                    state.capturedQC = nil
                    state.overload   = false
                    LOGD("[BOMBA v2] capture cleared")
                end
                ImGui.SameLine()
                if ImGui.Button("Reset Counter##ov", {140, 28}) then
                    state.floodsFired = 0
                end
                ImGui.PopStyleColor(3)

                ImGui.Spacing()
                ImGui.PushStyleColor(ImGui.Col_Text, CLR.dim)
                ImGui.Text("How it works:")
                ImGui.Text("  RpcSendQuickChat hook captures a live data ptr on your first send.")
                ImGui.Text("  Overload replays that ptr N times per FixedUpdate frame to every")
                ImGui.Text("  connected client, overflowing their RPC receive queues.")
                ImGui.Text("  If capture goes stale (GC) overload auto-stops; send one QuickChat")
                ImGui.Text("  to re-arm.")
                ImGui.PopStyleColor()

                ImGui.EndTabItem()
            end

            -- ────────────────────────────────────────────────────────────────
            -- TAB : STEALTH
            -- ────────────────────────────────────────────────────────────────
            if ImGui.BeginTabItem("  Stealth  ") then
                ImGui.Spacing()
                state.godMode, _ = ImGui.Checkbox(
                    "God Mode  (Die hook skips original body)", state.godMode)
                ImGui.Spacing()
                state.invisible, _ = ImGui.Checkbox(
                    "Invisible  (invisibilityAlpha=0.0, shouldAppearInvisible=true)",
                    state.invisible)

                ImGui.Spacing()
                ImGui.Separator()
                ImGui.Spacing()
                ImGui.Text("Name Spoof")
                ImGui.Spacing()

                ImGui.PushItemWidth(250)
                state.nameInput, _ = ImGui.InputText("##name", state.nameInput, 64)
                ImGui.PopItemWidth()
                ImGui.SameLine()

                ImGui.PushStyleColor(ImGui.Col_Button,        CLR.btn)
                ImGui.PushStyleColor(ImGui.Col_ButtonHovered, CLR.btn_h)
                ImGui.PushStyleColor(ImGui.Col_ButtonActive,  CLR.btn_a)
                if ImGui.Button("Set##n", {64, 26}) then doSetName() end
                ImGui.PopStyleColor(3)

                ImGui.Spacing()
                ImGui.Separator()
                ImGui.Spacing()
                ImGui.PushStyleColor(ImGui.Col_Text, CLR.dim)
                ImGui.Text("hooks: FixedUpdate / RpcSendQuickChat / IsKillTimerEnabled / Die")
                ImGui.Text("all sigs carry trailing ptr (MethodInfo* ARM ABI)")
                ImGui.PopStyleColor()

                ImGui.EndTabItem()
            end

            ImGui.EndTabBar()
        end
    end

    ImGui.TouchRectCurrentWindow()
    ImGui.End()
end

function DrawImGui(width, height)
    ImGui.PushStyleColor(ImGui.Col_WindowBg,      CLR.bg)
    ImGui.PushStyleColor(ImGui.Col_FrameBg,       CLR.frame)
    ImGui.PushStyleColor(ImGui.Col_Button,        CLR.btn)
    ImGui.PushStyleColor(ImGui.Col_ButtonHovered, CLR.btn_h)
    ImGui.PushStyleColor(ImGui.Col_ButtonActive,  CLR.btn_a)

    local ok, err = pcall(innerDraw, width, height)

    ImGui.PopStyleColor(5)

    if not ok then
        LOGD("[BOMBA v2] DrawImGui ERR: %s", tostring(err))
    end
end


-- ── BOOT ─────────────────────────────────────────────────────────────────────

LOGD("[BOMBA v2] loaded")
LOGD("[BOMBA v2] hooks registered: FixedUpdate, RpcSendQuickChat, IsKillTimerEnabled, Die")
LOGD("[BOMBA v2] RpcSendQuickChat RVA 0x21CE9D8 — capture fires on first natural QC send")
return "BOMBA v2 loaded"
