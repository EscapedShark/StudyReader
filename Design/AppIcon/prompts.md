# App icon background removal

Edited with the built-in image_gen tool from `/Users/dxcfw/Downloads/logo.png`. The original file is retained unchanged.

- macOS: `StudyReader/Assets.xcassets/AppIcon.appiconset/icon-1024.png` is the master; smaller Mac slots are resampled from it.
- iOS: `StudyReader/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png` is the opaque, full-bleed master; iOS supplies the corner mask.

## Prompts

The first macOS extraction was rejected because of visible edge specks. The macOS assets use the refined prompt below, with the accepted iOS icon as input.

### Final macOS cutout

Use case: background-extraction. Edit the attached FULL-BLEED BLUE square application icon into a macOS icon with actual transparent alpha outside. Preserve the attached artwork exactly: white folded sheet, dark capital M, three horizontal blue-gray lines, blue gradient. Apply only a clean smooth rounded-square/squircle silhouette to the blue background, with corner radius roughly 22% of its width. Fit this rounded blue icon centered in a square canvas with 6% transparent padding on each side. Only the blue rounded icon and its white document remain. Everything outside the ONE continuous rounded-square silhouette must have exactly zero alpha. NO exterior shadow, NO stray colored pixels, NO blue or cyan specks, NO fringe, NO rough fuzzy boundary, NO halo, NO white border, NO frame. Use a clean vector-quality antialiased contour. The transparent area must be actually transparent, never painted black, gray, white, or a checkerboard. Keep all white areas INSIDE the document fully opaque and preserve all internal shapes, typography, gradients and shadows. Output a single 1024x1024 transparent PNG macOS app icon.

### studyreader_mac_icon_cutout

Use case: background-extraction. Edit target: the attached existing StudyReader application logo. Make a precise background removal, NOT a redesign. Remove all white / off-white background OUTSIDE the blue rounded square, including the external gray cast shadow; those exterior pixels must be genuinely transparent alpha, never a checkerboard illustration, never black, never white. Keep the entire blue rounded square with its existing smooth blue gradient, geometry, rounded corner radii, and proportions. Preserve the white folded sheet INSIDE the blue square, the dark exact capital M, the three blue-gray horizontal lines, and all their interior shadows and positions with highest possible fidelity. Do not cut out any white INSIDE the blue rounded square. The blue icon should occupy about 88% of a square 1024 x 1024 canvas, centered with modest transparent padding that matches the original image layout, no white outline or rim. Output a single 1024 x 1024 transparent PNG asset suitable for a macOS app icon, not a mockup, not a screenshot. No other changes.

### studyreader_ios_icon_bleed

Use case: precise-object-edit. Edit target: the attached existing StudyReader application logo, for an iPhone app icon. Remove the exterior white / off-white border/background and the external gray shadow. Enlarge/reframe the existing blue square to fill the whole 1024 x 1024 canvas, and extend its smooth blue gradient fully into all four corners so the final PNG is a fully opaque SQUARE with blue reaching EVERY edge and corner. There must be no pre-rounded exterior mask, no white outer margin, no transparency, no exterior shadow; iOS will apply its own corner mask. Preserve the white folded sheet INSIDE, the exact dark capital M, the three blue-gray lines and their spacing, paper proportions, fold and subtle internal shadows. Match the original artwork closely, no redesign or added elements. The white folded sheet should occupy roughly 67% of canvas width and 77% of canvas height, centered as in the original blue area. Only remove the outer white background and turn the blue background into a full-bleed square. Output one clean 1024 x 1024 iOS app icon asset, not a mockup or screen.
