// AppKit Compatibility Shim for Xcode 8.3.3 on macOS 26
//
// Old Xcode binaries reference private ivar offset symbols that modern AppKit
// no longer exports. This shim exports those symbols and sets them to the
// correct runtime values using the Objective-C runtime API.
//
// The symbols are ptrdiff_t globals containing the byte offset of each ivar
// within its class instance. Symbol names contain $ and . characters, so we
// use __asm__ labels to set the correct exported names.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdio.h>

// Exported ivar offset symbols with correct mangled names.
// The __asm__ attribute sets the actual symbol name in the binary.

// NSFont._fFlags (fully opaque in modern AppKit)
ptrdiff_t nsFont_fFlags __asm__("_OBJC_IVAR_$_NSFont._fFlags") = 0;

// NSText._ivars
ptrdiff_t nsText_ivars __asm__("_OBJC_IVAR_$_NSText._ivars") = 0;

// NSTextStorage
ptrdiff_t nsTextStorage_editedDelta __asm__("_OBJC_IVAR_$_NSTextStorage._editedDelta") = 0;
ptrdiff_t nsTextStorage_editedRange __asm__("_OBJC_IVAR_$_NSTextStorage._editedRange") = 0;
ptrdiff_t nsTextStorage_flags __asm__("_OBJC_IVAR_$_NSTextStorage._flags") = 0;

// NSATSTypesetter
ptrdiff_t nsATSTypesetter_lineFragmentPadding __asm__("_OBJC_IVAR_$_NSATSTypesetter.lineFragmentPadding") = 0;

// NSTextViewIvars (private class)
ptrdiff_t nsTextViewIvars_sharedData __asm__("_OBJC_IVAR_$_NSTextViewIvars.sharedData") = 0;
ptrdiff_t nsTextViewIvars_tvFlags __asm__("_OBJC_IVAR_$_NSTextViewIvars.tvFlags") = 0;

// NSTextViewSharedData
ptrdiff_t nsTextViewSharedData_sdFlags __asm__("_OBJC_IVAR_$_NSTextViewSharedData._sdFlags") = 0;

// NSUndoTextOperation
ptrdiff_t nsUndoTextOperation_layoutManager __asm__("_OBJC_IVAR_$_NSUndoTextOperation._layoutManager") = 0;

// Helper: resolve an ivar offset from the runtime
static ptrdiff_t resolveIvar(const char *className, const char *ivarName, ptrdiff_t fallback) {
    Class cls = objc_getClass(className);
    if (!cls) {
        fprintf(stderr, "[appkit_compat] WARNING: Class %s not found, using fallback offset %td\n",
                className, fallback);
        return fallback;
    }

    Ivar ivar = class_getInstanceVariable(cls, ivarName);
    if (!ivar) {
        fprintf(stderr, "[appkit_compat] WARNING: Ivar %s.%s not found, using fallback offset %td\n",
                className, ivarName, fallback);
        return fallback;
    }

    ptrdiff_t offset = ivar_getOffset(ivar);
    fprintf(stderr, "[appkit_compat] Resolved %s.%s -> offset %td\n",
            className, ivarName, offset);
    return offset;
}

// Constructor: runs before main(), resolves all ivar offsets from the runtime
__attribute__((constructor))
static void appkit_compat_init(void) {
    fprintf(stderr, "[appkit_compat] Initializing AppKit compatibility shim for Xcode 8.3.3\n");

    // NSFont._fFlags - this ivar no longer exists in modern NSFont.
    // NSFont is now fully opaque (0 runtime ivars). We set this to a safe
    // offset (8 = past isa pointer). Code that reads _fFlags from an NSFont
    // will read zeros (from zeroed allocation memory), which is safe for
    // flag checks. This may cause incorrect display but won't crash.
    nsFont_fFlags = 8;
    fprintf(stderr, "[appkit_compat] NSFont._fFlags -> dummy offset 8 (class is opaque)\n");

    // NSText._ivars - exists in modern runtime
    nsText_ivars = resolveIvar("NSText", "_ivars", 536);

    // NSTextStorage ivars - all exist in modern runtime
    nsTextStorage_editedDelta = resolveIvar("NSTextStorage", "_editedDelta", 56);
    nsTextStorage_editedRange = resolveIvar("NSTextStorage", "_editedRange", 40);
    nsTextStorage_flags = resolveIvar("NSTextStorage", "_flags", 64);

    // NSATSTypesetter - exists in modern runtime
    nsATSTypesetter_lineFragmentPadding =
        resolveIvar("NSATSTypesetter", "lineFragmentPadding", 64);

    // NSTextViewIvars - private internal class, may not exist
    nsTextViewIvars_sharedData = resolveIvar("NSTextViewIvars", "sharedData", 0);
    nsTextViewIvars_tvFlags = resolveIvar("NSTextViewIvars", "tvFlags", 0);

    // NSTextViewSharedData - exists in modern runtime
    nsTextViewSharedData_sdFlags = resolveIvar("NSTextViewSharedData", "_sdFlags", 8);

    // NSUndoTextOperation - may have been restructured
    nsUndoTextOperation_layoutManager =
        resolveIvar("NSUndoTextOperation", "_layoutManager", 0);

    fprintf(stderr, "[appkit_compat] Shim initialization complete\n");
}
