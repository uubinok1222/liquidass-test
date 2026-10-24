#pragma once
#import <UIKit/UIKit.h>

#define XC_STRETCH_MAX 0.8

typedef struct {
    BOOL valid;
    BOOL glass;
    double stretch;
    double clarity;
    double distortion;
} XCStyleValue;

BOOL XCClockStyleGlassOn(void);
double XCStyleSignature(void);
id XCStylePreferenceOverride(NSString *key);
BOOL XCProcessHostsClock(void);
BOOL XCHostShouldRender(UIView *host);
void XCSyncHostTransform(UIView *host);
void XCNoteClockHost(UIView *host);
void XCSyncGlassParams(id glass);
CGAffineTransform XCStretchTransform(CGFloat anchorY);
void XCStyleDidChange(void);
void XCSetActivePosterVC(UIViewController *vc);
void XCEditBegin(NSUUID *uuid);
void XCEditEnd(void);
BOOL XCEditActive(void);
XCStyleValue XCEditGet(void);
void XCEditSet(XCStyleValue v);
void XCEditCommit(void);
void XCLogf(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
XCStyleValue XCCurrentStyle(void);
BOOL XCIsSpringBoard(void);
void XCSetTint(UIColor *c);
UIColor *XCCurrentTintColor(void);
BOOL XCVarHeightRange(double *mn, double *mx);
