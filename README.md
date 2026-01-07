# DF-Autopilot

An advanced, autonomous fortress management system for **Dwarf Fortress** (via DFHack). This AI agent takes control of your dwarves to plan, dig, and build a safe, functional, and thriving fortress without user intervention.

## Key Features

### Fortress Planner & Pathfinding
The core of the system is a deterministic, modular layout generator powered by **A* Pathfinding**.

-   **A* Ramp Generation**: Uses a custom 3D A* algorithm to find an optimal, hazard-free wagon path from the surface to the Trade Depot. It proactively avoids aquifers, magma, and caverns while ensuring a 3-tile wide clearance for wagons.
-   **Hub-and-Spoke Layout**: Designed around a central 3x3 stairwell that acts as the main artery of the fortress, connecting all vertical levels.
-   **Dedicated Zoning**: Automatically designates specific Z-levels for distinct functions (Entrance, Workshop, Storage, Living).
-   **Wagon Accessibility**: Ensures the fortress is accessible to trade caravans by generating guaranteed 3-tile wide ramps and tunnels.

### Automated Defense Systems
-   **Trap Hall**: Automatically designs and constructs a defensive choke point full of traps. It intelligently checks stock and prioritizes **Cage Traps** for live capture, falling back to **Stone-Fall Traps**.
-   **Emergency Burrows**: Detects sieges and ambushes in real-time. Automatically creates a "Siege Safe" burrow deep underground and restricts all civilians to safety until the threat is neutralized.

### Noble & Military Management
-   **Dynamic Noble Housing**: Periodically scans for unsatisfied nobles and automatically assigns them appropriate vacant rooms (Offices, Dining halls, Bedrooms). Assignments are prioritized by **noble precedence** (Monarch > Duke > ... > Bookkeeper).
-   **Smart Military Logic**: Logistics manager now verifies resource availability (metal bars) before queuing equipment production, preventing job cancellation spam. Recruitment prioritizes dwarves with superior physical attributes.

### Advanced Terrain Analysis
Safety is paramount. The system uses a sophisticated terrain scanner (`terrain.lua`) before making any decisions.

- **Aquifer Avoidance**: Automatically detects damp stone layers. If an aquifer is found at the planned Trade Depot level, the system dynamically scans deeper to find a dry, safe Z-level to build on.
- **Lateral Safety Checks**: Prevents "fortress leaks" by scanning the neighbors of every planned wall tile. It will not dig if it detects adjacent open space (cliffs) or outdoors, ensuring the fortress remains enclosed.
- **Vertical Enclosure**: Verifies that the main fortress hub is built deep enough to have a solid rock ceiling, preventing accidental surface breaches.
- **Hazard Detection**: Automatically avoids digging near magma, water, or cavern layers unless explicitly planned.

### Intelligent Mining & Construction
- **Ramp Preservation**: Utilizes a specific digging sequence (Channel Surface -> Dig Tunnel) to ensure entrance ramps are constructed correctly and remain walkable.
- **Validated Designations**: Every dig command is cross-referenced with the terrain scanner. Unsafe commands are blocked and logged.
- **Deterministic Room Placement**: Uses a grid-based approach for core rooms to guarantee connectivity, avoiding the pitfalls of random hallway generation.
- **L/T-Shaped Rooms**: Adds variety to the layout by procedurally generating L-shaped and T-shaped rooms for Dining Halls and meeting areas.

### Autonomous Management
- **Phase-Based Decisions**: The AI tracks the fortress's maturity through defined phases (`EMBARK`, `ESTABLISHING`, `STABLE`, `EXPANDING`, `THRIVING`) and adjusts priorities accordingly.
- **Crisis Management**: Continuously monitors dwarf mood and health strings. It can detect potential interactions or tantrum spirals and adjust priorities ($brain.lua$).
- **Auto-Zoning**: Automatically converts dug-out rooms into their appropriate Zone types (Bedroom, Dining Hall, etc.) upon completion.

## Installation

1. Ensure **DFHack** is installed for your version of Dwarf Fortress (v50+).
2. Clone or copy this repository into your `Dwarf Fortress` directory:
   - Scripts go to: `Dwarf Fortress/hack/scripts/df-autopilot/`
   - Configs go to: `Dwarf Fortress/dfhack-config/df-autopilot/`
3. The included `.gitignore` is optimized for development deeply nested inside the game folder (ignoring game binaries and save data).

## Usage

Start the AI from the DFHack console:

```lua
df-autopilot enable
```

To stop:
```lua
df-autopilot disable
```

## Requirements
- Dwarf Fortress (Steam Edition / v50+)
- DFHack

## License
MIT
