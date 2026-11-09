# Flip

Adds **Flip Horizontal / Flip Vertical** buttons and an **Image Orientation** menu (0°, 90° right, 180°, 90° left) to the Transform section of the Video inspector.

## Why

Mirroring or rotating a shot in Final Cut means typing −100 into Scale X, or using Rotation and then fixing the scale yourself because the frame no longer fills. Phone and gimbal footage often arrives sideways. Resolve has flip buttons right in the Transform panel; these follow the same idea.

## How it works

- Buttons flip the Scale X / Scale Y sign through the same path as typing a value: one undoable edit.
- Image Orientation uses Final Cut's own rotation + scale, compensating for Spatial Conform so a 90° turn still fills the frame.
- Drawn with the inspector's own colours and fonts.

## Requires

Nothing.

## Install

```sh
./install.sh flip
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall flip`. Log: `~/Library/Logs/SpliceKit/`.
