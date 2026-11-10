# Lucide icons

source: https://github.com/lucide-icons/lucide

revision: `53fab88ff9d1b48f4704b5b5b560d6b4d560bf4c`

the SVGs come from the upstream `icons/` directory and are optimized with SVGO. `LICENSE` is copied from the repository root.

34 SVGs are embedded: file-type and places icons, sort indicators, breadcrumb and copy controls, an unmount icon, file-action menu icons, and a shared x icon for tabs and transfers. the documents place reuses the document icon. SDL3_image renders them at the current display scale. the renderer replaces `currentColor` with white before loading, then applies a neutral gray texture color. the geometry is unchanged.
