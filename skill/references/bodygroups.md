# s&box bodygroups

Bodygroups are a `System.UInt64` bitmask on `SkinnedModelRenderer` (`BodyGroups` property)
that controls which body parts of a model are visible. Each bodygroup occupies a fixed bit
range; setting a bodygroup's bits to zero hides that body part.

## Querying bodygroups

```bash
model_list_body_groups(path="models/citizen/citizen.vmdl")
```

Returns the bodygroup definitions (name, mask, choices) and the model's default mask.

## Setting bodygroups

```bash
# On the SkinnedModelRenderer component of the Body child:
set_property(id="<body-gameobject-id>", component_type="Sandbox.SkinnedModelRenderer",
             name="BodyGroups", value=<new-mask>)
```

The value is a `System.UInt64` integer. Compute it by summing the desired choice masks.

---

## Citizen model (`models/citizen/citizen.vmdl`)

Bodygroups: 5 groups, default mask = `341` (all visible).

| Index | Name   | Mask bits | Visible choice        | Hidden choice |
|-------|--------|-----------|----------------------|---------------|
| 0     | Head   | 1         | head_lod0 (1)        |: (0)         |
| 1     | Chest  | 4         | torso_lod0 (4)       |: (0)         |
| 2     | Legs   | 16        | legs_lod0 (16)       |: (0)         |
| 3     | Hands  | 64        | hands_lod0 (64)      |: (0)         |
| 4     | Feet   | 256       | feet_lod0 (256)      |: (0)         |

### Common presets

| Mask | Head | Chest | Legs | Hands | Feet | Use case |
|------|------|-------|------|-------|------|----------|
| 341  | ✓    | ✓     | ✓    | ✓     | ✓    | Default (third person) |
| 340  | ✗    | ✓     | ✓    | ✓     | ✓    | First person: hide head only |
| 324  | ✗    | ✗     | ✓    | ✓     | ✓    | Minimal first person (legs + hands + feet) |
| 80   | ✗    | ✗     | ✓    | ✗     | ✓    | Legs + feet only |
| 261  | ✗    | ✓     | ✗    | ✓     | ✓    | Torso + hands + feet (no head, no legs) |

### How the mask works

Each choice has a `mask` value. The total `BodyGroups` value is the bitwise OR of the
chosen option masks per group. For the citizen:

```
Default (341) = 1 (head) | 4 (chest) | 16 (legs) | 64 (hands) | 256 (feet)
No head (340) = 0 (head) | 4 (chest) | 16 (legs) | 64 (hands) | 256 (feet)
```

The `mask` field on each bodygroup in the model def tells you which bits belong to that
group: they're always disjoint ranges. Use the choices' individual masks for the math.

---

## Other models

The bodygroup structure varies per model. Always call `model_list_body_groups` first to
get the actual layout. The mask values and group count are model-specific; don't assume
the citizen layout applies to other models.
