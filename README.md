# DF-Autopilot 🏰🤖

An advanced, autonomous fortress management system for **Dwarf Fortress** (via DFHack). This AI agent takes control of your dwarves to plan, dig, and build a safe, functional, and thriving fortress without user intervention.

## 🚀 Key Features

### 🧠 Fortress Planner 2.0
- **Deterministic Hub-and-Spoke Layout**: Generates a clean, efficient fortress with a central stairwell connecting dedicated functional levels (Workshops, Storage, Living).
- **Smart Entrance**: Automatically carves a **3-wide ramp** and tunnel for wagon access.
- **Trade Ready**: Builds a **Trade Depot** near the surface (with aquifer detection) and a secure **Trap Hall** to defend the interior.
- **Safety First**: Uses advanced terrain analysis to avoid **Aquifers**, **Magma**, **Caves**, and **Open Space** (cliffs).

### ⛏️ Intelligent Mining
- **Hazard Avoidance**: `terrain.lua` scans neighbors to prevent accidental flooding or breaching into the outdoors.
- **Aquifer Handling**: Automatically probes deeper Z-levels if the surface layers are wet, ensuring your main hub is always dry.
- **Ramp Preservation**: Correctly handles digging sequences (Channel -> Dig) to preserve ramps for accessibility.

### ⚙️ Autonomous Management
- **Phase-Based Decisions**: The AI adapts its strategy based on fortress maturity (`EMBARK` -> `ESTABLISHING` -> `THRIVING`).
- **Crisis Management**: Automatic detection of threats and mood spirals (`brain.lua`).

## 📦 Installation

1. Ensure **DFHack** is installed for your version of Dwarf Fortress.
2. Clone or copy this repository into your `Dwarf Fortress` directory:
   - Scripts go to: `Dwarf Fortress/hack/scripts/df-autopilot/`
   - Configs go to: `Dwarf Fortress/dfhack-config/df-autopilot/`
3. (Optional) The included `.gitignore` is optimized for development inside the game folder (ignoring game asset files).

## 🎮 Usage

Start the AI from the DFHack console:

```lua
df-autopilot enable
```

To stop:
```lua
df-autopilot disable
```

## 🛠️ Requirements
- Dwarf Fortress (v50+)
- DFHack

## 📝 License
MIT
