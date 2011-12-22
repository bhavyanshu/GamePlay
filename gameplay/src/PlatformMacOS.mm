#ifdef __APPLE__

#include "Base.h"
#include "Platform.h"
#include "FileSystem.h"
#include "Game.h"

#import <Cocoa/Cocoa.h>
#import <QuartzCore/CVDisplayLink.h>
#import <OpenGL/OpenGL.h>
#import <mach/mach_time.h>

using namespace std;
using namespace gameplay;

static const float ACCELEROMETER_X_FACTOR = 90.0f / WINDOW_WIDTH;
static const float ACCELEROMETER_Y_FACTOR = 90.0f / WINDOW_HEIGHT;

static long __timeStart;
static long __timeAbsolute;
static bool __vsync = WINDOW_VSYNC;
static float __pitch;
static float __roll;
static int __lx;
static int __ly;
static bool __hasMouse = false;
static bool __leftMouseDown = false;
static bool __rightMouseDown = false;
static bool __shiftDown = false;

long getMachTimeInMilliseconds()
{
    static const int64_t kOneMillion = 1000 * 1000;
    static mach_timebase_info_data_t s_timebase_info;
    
    if (s_timebase_info.denom == 0) 
        (void) mach_timebase_info(&s_timebase_info);
    
    // mach_absolute_time() returns billionth of seconds, so divide by one million to get milliseconds
    return (long)((mach_absolute_time() * s_timebase_info.numer) / (kOneMillion * s_timebase_info.denom));
}


@class View;

@interface View : NSOpenGLView <NSWindowDelegate> 
{
    CVDisplayLinkRef displayLink;
    NSRecursiveLock* lock;
    Game* _game;
}

@end


static View* __view = NULL;

@implementation View

-(void)windowWillClose:(NSNotification*)note 
{
    [lock lock];
    _game->exit();
    [lock unlock];
    [[NSApplication sharedApplication] terminate:self];
}


- (CVReturn) getFrameForTime:(const CVTimeStamp*)outputTime
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    
    [self update];
    
    [pool release];
    
    return kCVReturnSuccess;
}

-(void) update
{       
    [lock lock];

    [[self openGLContext] makeCurrentContext];
    
    CGLLockContext((CGLContextObj)[[self openGLContext] CGLContextObj]);
    
    if (_game && _game->getState() == Game::RUNNING)       
        _game->frame();
    
    CGLFlushDrawable((CGLContextObj)[[self openGLContext] CGLContextObj]);
    CGLUnlockContext((CGLContextObj)[[self openGLContext] CGLContextObj]);  
    
    [lock unlock];
}

static CVReturn MyDisplayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp* now, const CVTimeStamp* outputTime, 
                                      CVOptionFlags flagsIn, CVOptionFlags* flagsOut, void* displayLinkContext)
{
    CVReturn result = [(View*)displayLinkContext getFrameForTime:outputTime];
    return result;
}

- (id) initWithFrame: (NSRect) frame
{    
    lock = [[NSRecursiveLock alloc] init];
    _game = Game::getInstance();
    __timeStart = getMachTimeInMilliseconds();
    NSOpenGLPixelFormatAttribute attrs[] = 
    {
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 32,
        NSOpenGLPFADepthSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy,
        0
    };
    
    NSOpenGLPixelFormat* pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    if (!pf)
        NSLog(@"OpenGL pixel format not supported.");
    
    self = [super initWithFrame:frame pixelFormat:[pf autorelease]];  
    
    return self;
}

- (void) prepareOpenGL
{
    [super prepareOpenGL];
    
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString* path = [bundlePath stringByAppendingString:@"/Contents/Resources/"];
    FileSystem::setResourcePath([path cStringUsingEncoding:NSASCIIStringEncoding]);
    _game->run(WINDOW_WIDTH, WINDOW_HEIGHT);
    
    [[self window] setLevel: NSFloatingWindowLevel];
    [[self window] makeKeyAndOrderFront: self];
    [[self window] setTitle: [NSString stringWithUTF8String: ""]];
    
    // Make all the OpenGL calls to setup rendering and build the necessary rendering objects
    [[self openGLContext] makeCurrentContext];
    // Synchronize buffer swaps with vertical refresh rate
    GLint swapInt = __vsync ? 1 : 0;
    [[self openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval];
    
    // Create a display link capable of being used with all active displays
    CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    
    // Set the renderer output callback function
    CVDisplayLinkSetOutputCallback(displayLink, &MyDisplayLinkCallback, self);
    
    CGLContextObj cglContext = (CGLContextObj)[[self openGLContext] CGLContextObj];
    CGLPixelFormatObj cglPixelFormat = (CGLPixelFormatObj)[[self pixelFormat] CGLPixelFormatObj];
    CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(displayLink, cglContext, cglPixelFormat);
    
    // Activate the display link
    CVDisplayLinkStart(displayLink);
}

- (void) dealloc
{   
    [lock lock];
    
    // Release the display link
    CVDisplayLinkStop(displayLink);
    CVDisplayLinkRelease(displayLink);
    
    _game->exit();
    
    [lock unlock];

    [super dealloc];
}

- (void) mouseDown: (NSEvent*) event
{
    NSPoint point = [event locationInWindow];
    __leftMouseDown = true;
    _game->touchEvent(Touch::TOUCH_PRESS, point.x, WINDOW_HEIGHT - point.y, 0);
}

- (void) mouseUp: (NSEvent*) event
{
    NSPoint point = [event locationInWindow];
    __leftMouseDown = false;
    _game->touchEvent(Touch::TOUCH_RELEASE, point.x, WINDOW_HEIGHT - point.y, 0);
}

- (void) mouseDragged: (NSEvent*) event
{
    NSPoint point = [event locationInWindow];
    if (__leftMouseDown)
    {
        _game->touchEvent(Touch::EVENT_MOVE, point.x, WINDOW_HEIGHT - point.y, 0);
    }
}

- (void) rightMouseDown: (NSEvent*) event
{
    __rightMouseDown = true;
     NSPoint point = [event locationInWindow];
    __lx = point.x;
    __ly = WINDOW_HEIGHT - point.y;
}

- (void) rightMouseUp: (NSEvent*) event
{
   __rightMouseDown = false;
}

- (void) rightMouseDragged: (NSEvent*) event
{
    NSPoint point = [event locationInWindow];
    if (__rightMouseDown)
    {
        // Update the pitch and roll by adding the scaled deltas.
        __roll += -(float)(point.x - __lx) * ACCELEROMETER_X_FACTOR;
        __pitch -= (float)(point.y - (WINDOW_HEIGHT - __ly)) * ACCELEROMETER_Y_FACTOR;
    
        // Clamp the values to the valid range.
        __roll = max(min(__roll, 90.0f), -90.0f);
        __pitch = max(min(__pitch, 90.0f), -90.0f);
    
        // Update the last X/Y values.
        __lx = point.x;
        __ly = (WINDOW_HEIGHT - point.y);
    }
}

- (void) mouseEntered: (NSEvent*)event
{
    __hasMouse = true;
}

- (void) mouseExited: (NSEvent*)event
{
    __leftMouseDown = false;
    __rightMouseDown = false;
    __hasMouse = false;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

int getKey(unsigned short keyCode, unsigned int modifierFlags)
{
    __shiftDown = (modifierFlags & NSShiftKeyMask);
    switch(keyCode)
    {
        case 0x69:
            return Keyboard::KEY_PRINT;
        case 0x35:
            return Keyboard::KEY_ESCAPE;
        case 0x33:
            return Keyboard::KEY_BACKSPACE;
        case 0x30:
            return Keyboard::KEY_TAB;
        case 0x24:
            return Keyboard::KEY_RETURN;
        case 0x72:
            return Keyboard::KEY_INSERT;
        case 0x73:
            return Keyboard::KEY_HOME;
        case 0x74:
            return Keyboard::KEY_PG_UP;
        case 0x79:
            return Keyboard::KEY_PG_DOWN;
        case 0x75:
            return Keyboard::KEY_DELETE;
        case 0x77:
            return Keyboard::KEY_END;
        case 0x7B:
            return Keyboard::KEY_LEFT_ARROW;
        case 0x7C:
            return Keyboard::KEY_RIGHT_ARROW;
        case 0x7E:
            return Keyboard::KEY_UP_ARROW;
        case 0x7D:
            return Keyboard::KEY_DOWN_ARROW;
        case 0x47:
            return Keyboard::KEY_NUM_LOCK;
        case 0x45:
            return Keyboard::KEY_KP_PLUS;
        case 0x4E:
            return Keyboard::KEY_KP_MINUS;
        case 0x43:
            return Keyboard::KEY_KP_MULTIPLY;
        case 0x4B:
            return Keyboard::KEY_KP_DIVIDE;
        case 0x59:
            return Keyboard::KEY_KP_HOME;
        case 0x5B:
            return Keyboard::KEY_KP_UP;
        case 0x5C:
            return Keyboard::KEY_KP_PG_UP;
        case 0x56:
            return Keyboard::KEY_KP_LEFT;
        case 0x57:
            return Keyboard::KEY_KP_FIVE;
        case 0x58:
            return Keyboard::KEY_KP_RIGHT;
        case 0x53:
            return Keyboard::KEY_KP_END;
        case 0x54:
            return Keyboard::KEY_KP_DOWN;
        case 0x55:
            return Keyboard::KEY_KP_PG_DOWN;
        case 0x52:
            return Keyboard::KEY_KP_INSERT;
        case 0x41:
            return Keyboard::KEY_KP_DELETE;
        case 0x7A:
            return Keyboard::KEY_F1;
        case 0x78:
            return Keyboard::KEY_F2;
        case 0x63:
            return Keyboard::KEY_F3;
        case 0x76:
            return Keyboard::KEY_F4;
        case 0x60:
            return Keyboard::KEY_F5;
        case 0x61:
            return Keyboard::KEY_F6;
        case 0x62:
            return Keyboard::KEY_F7;
        case 0x64:
            return Keyboard::KEY_F8;
        case 0x65:
            return Keyboard::KEY_F9;
        case 0x6D:
            return Keyboard::KEY_F10;
        
        // MACOS reserved:
        //return Keyboard::KEY_F11;
        //return Keyboard::KEY_F12;
        // return Keyboard::KEY_PAUSE;
        // return Keyboard::KEY_SCROLL_LOCK;
            
        case 0x31:
            return Keyboard::KEY_SPACE;
        case 0x1D:
            return __shiftDown ? Keyboard::KEY_RIGHT_PARENTHESIS : Keyboard::KEY_ZERO;
        case 0x12:
            return __shiftDown ? Keyboard::KEY_EXCLAM : Keyboard::KEY_ONE;
        case 0x13:
            return __shiftDown ? Keyboard::KEY_AT : Keyboard::KEY_TWO;
        case 0x14:
            return __shiftDown ? Keyboard::KEY_NUMBER : Keyboard::KEY_THREE;
        case 0x15:
            return __shiftDown ? Keyboard::KEY_DOLLAR : Keyboard::KEY_FOUR;
        case 0x17:
            return __shiftDown ? Keyboard::KEY_PERCENT : Keyboard::KEY_FIVE;
        case 0x16:
            return __shiftDown ? Keyboard::KEY_CIRCUMFLEX : Keyboard::KEY_SIX;
        case 0x1A:
            return __shiftDown ? Keyboard::KEY_AMPERSAND : Keyboard::KEY_SEVEN;
        case 0x1C:
            return __shiftDown ? Keyboard::KEY_ASTERISK : Keyboard::KEY_EIGHT;
        case 0x19:
            return __shiftDown ? Keyboard::KEY_LEFT_PARENTHESIS : Keyboard::KEY_NINE;
        case 0x18:
            return __shiftDown ? Keyboard::KEY_EQUAL : Keyboard::KEY_PLUS;
        case 0x2B:
            return __shiftDown ? Keyboard::KEY_LESS_THAN : Keyboard::KEY_COMMA;
        case 0x1B:
            return __shiftDown ? Keyboard::KEY_UNDERSCORE : Keyboard::KEY_MINUS;
        case 0x2F:
            return __shiftDown ? Keyboard::KEY_GREATER_THAN : Keyboard::KEY_PERIOD;
        case 0x29:
            return __shiftDown ? Keyboard::KEY_COLON : Keyboard::KEY_SEMICOLON;
        case 0x2C:
            return __shiftDown ? Keyboard::KEY_QUESTION : Keyboard::KEY_SLASH;
        case 0x32:
            return __shiftDown ? Keyboard::KEY_GRAVE : Keyboard::KEY_TILDE;
        case 0x21:
            return __shiftDown ? Keyboard::KEY_LEFT_BRACE : Keyboard::KEY_LEFT_BRACKET;
        case 0x2A:
            return __shiftDown ? Keyboard::KEY_BAR : Keyboard::KEY_BACK_SLASH;
        case 0x1E:
            return __shiftDown ? Keyboard::KEY_RIGHT_BRACE : Keyboard::KEY_RIGHT_BRACKET;
        case 0x27:
            return __shiftDown ? Keyboard::KEY_QUOTE : Keyboard::KEY_APOSTROPHE;
            
        case 0x00:
             return __shiftDown ? Keyboard::KEY_CAPITAL_A : Keyboard::KEY_A;
        case 0x0B:
             return __shiftDown ? Keyboard::KEY_CAPITAL_B : Keyboard::KEY_B;
        case 0x08:
             return __shiftDown ? Keyboard::KEY_CAPITAL_C : Keyboard::KEY_C;
        case 0x02:
             return __shiftDown ? Keyboard::KEY_CAPITAL_D : Keyboard::KEY_D;
        case 0x0E:
             return __shiftDown ? Keyboard::KEY_CAPITAL_E : Keyboard::KEY_E;
        case 0x03:
             return __shiftDown ? Keyboard::KEY_CAPITAL_F : Keyboard::KEY_F;
        case 0x05:
             return __shiftDown ? Keyboard::KEY_CAPITAL_G : Keyboard::KEY_G;
        case 0x04:
             return __shiftDown ? Keyboard::KEY_CAPITAL_H : Keyboard::KEY_H;
        case 0x22:
             return __shiftDown ? Keyboard::KEY_CAPITAL_I : Keyboard::KEY_I;
        case 0x26:
             return __shiftDown ? Keyboard::KEY_CAPITAL_J : Keyboard::KEY_J;
        case 0x28:
             return __shiftDown ? Keyboard::KEY_CAPITAL_K : Keyboard::KEY_K;
        case 0x25:
             return __shiftDown ? Keyboard::KEY_CAPITAL_L : Keyboard::KEY_L;
        case 0x2E:
             return __shiftDown ? Keyboard::KEY_CAPITAL_M : Keyboard::KEY_M;
        case 0x2D:
             return __shiftDown ? Keyboard::KEY_CAPITAL_N : Keyboard::KEY_N;
        case 0x1F:
             return __shiftDown ? Keyboard::KEY_CAPITAL_O : Keyboard::KEY_O;
        case 0x23:
             return __shiftDown ? Keyboard::KEY_CAPITAL_P : Keyboard::KEY_P;
        case 0x0C:
             return __shiftDown ? Keyboard::KEY_CAPITAL_Q : Keyboard::KEY_Q;
        case 0x0F:
             return __shiftDown ? Keyboard::KEY_CAPITAL_R : Keyboard::KEY_R;
        case 0x01:
             return __shiftDown ? Keyboard::KEY_CAPITAL_S : Keyboard::KEY_S;
        case 0x11:
             return __shiftDown ? Keyboard::KEY_CAPITAL_T : Keyboard::KEY_T;
        case 0x20:
             return __shiftDown ? Keyboard::KEY_CAPITAL_U : Keyboard::KEY_U;
        case 0x09:
             return __shiftDown ? Keyboard::KEY_CAPITAL_V : Keyboard::KEY_V;
        case 0x0D:
             return __shiftDown ? Keyboard::KEY_CAPITAL_W : Keyboard::KEY_W;
        case 0x07:
             return __shiftDown ? Keyboard::KEY_CAPITAL_X : Keyboard::KEY_X;
        case 0x10:
            return __shiftDown ? Keyboard::KEY_CAPITAL_Y : Keyboard::KEY_Y;
        case 0x06:
            return __shiftDown ? Keyboard::KEY_CAPITAL_Z : Keyboard::KEY_Z;

        default:
            return Keyboard::KEY_NONE;
    }
}

- (void)flagsChanged: (NSEvent*)event
{
    unsigned int keyCode = [event keyCode];
    unsigned int flags = [event modifierFlags];
    switch (keyCode) 
    {
        case 0x39:
            _game->keyEvent((flags & NSAlphaShiftKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_CAPS_LOCK);
            break;
        case 0x38:
            _game->keyEvent((flags & NSShiftKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_LEFT_SHIFT);
            break;
        case 0x3C:
            _game->keyEvent((flags & NSShiftKeyMask) ? Keyboard::KEYEVENT_DOWN : Keyboard::KEY_RELEASE, Keyboard::KEY_RIGHT_SHIFT);
            break;
        case 0x3A:
            _game->keyEvent((flags & NSAlternateKeyMask) ? Keyboard::KEYEVENT_DOWN : Keyboard::KEY_RELEASE, Keyboard::KEY_LEFT_ALT);
            break;
        case 0x3D:
            _game->keyEvent((flags & NSAlternateKeyMask) ? Keyboard::KEYEVENT_DOWN : Keyboard::KEY_RELEASE, Keyboard::KEY_RIGHT_ALT);
            break;
        case 0x3B:
            _game->keyEvent((flags & NSControlKeyMask) ? Keyboard::KEYEVENT_DOWN : Keyboard::KEY_RELEASE, Keyboard::KEY_LEFT_CTRL);
            break;
        case 0x3E:
            _game->keyEvent((flags & NSControlKeyMask) ? Keyboard::KEYEVENT_DOWN : Keyboard::KEY_RELEASE, Keyboard::KEY_RIGHT_CTRL);
            break;
        case 0x37:
            _game->keyEvent((flags & NSCommandKeyMask) ? Keyboard::KEYEVENT_DOWN : Keyboard::KEY_RELEASE, Keyboard::KEY_LEFT_HYPER);
            break;
        case 0x36:
            _game->keyEvent((flags & NSCommandKeyMask) ? Keyboard::KEYEVENT_DOWN : Keyboard::KEY_RELEASE, Keyboard::KEY_RIGHT_HYPER);
            break;
    }
}

- (void) keyDown: (NSEvent*) event
{    
    _game->keyEvent(getKey([event keyCode], [event modifierFlags]), Keyboard::KEYEVENT_PRESS);
}

- (void) keyUp: (NSEvent*) event
{    
    _game->keyEvent(getKey([event keyCode], [event modifierFlags]), Keyboard::KEY_RELEASE);
}

@end


namespace gameplay
{

extern void printError(const char* format, ...)
{
    va_list argptr;
    va_start(argptr, format);
    vfprintf(stderr, format, argptr);
    fprintf(stderr, "\n");
    va_end(argptr);
}
    
    
Platform::Platform(Game* game)
: _game(game)
{
}

Platform::Platform(const Platform& copy)
{
    // hidden
}

Platform::~Platform()
{
}

Platform* Platform::create(Game* game)
{
    Platform* platform = new Platform(game);
    
    return platform;
}

int Platform::enterMessagePump()
{
    NSAutoreleasePool* pool = [NSAutoreleasePool new];
    NSApplication* NSApp = [NSApplication sharedApplication];
    NSRect screenBounds = [[NSScreen mainScreen] frame];
    NSRect viewBounds = NSMakeRect(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);
    
    __view = [[View alloc] initWithFrame:viewBounds];
    
    NSRect centered = NSMakeRect(NSMidX(screenBounds) - NSMidX(viewBounds),
                                 NSMidY(screenBounds) - NSMidY(viewBounds),
                                 viewBounds.size.width, 
                                 viewBounds.size.height);
    
    NSWindow* window = [[NSWindow alloc]
                        initWithContentRect:centered
                        styleMask:NSTitledWindowMask | NSClosableWindowMask
                        backing:NSBackingStoreBuffered
                        defer:NO];
    
    [window setContentView:__view];
    [window setDelegate:__view];
    [__view release];
    
    [NSApp run];
    
    [pool release];
    return EXIT_SUCCESS;
}
    
long Platform::getAbsoluteTime()
{
    __timeAbsolute = getMachTimeInMilliseconds();
    return __timeAbsolute;
}

void Platform::setAbsoluteTime(long time)
{
    __timeAbsolute = time;
}

bool Platform::isVsync()
{
    return __vsync;
}

void Platform::setVsync(bool enable)
{
    __vsync = enable;
}

int Platform::getOrientationAngle()
{
    return 0;
}

void Platform::getAccelerometerValues(float* pitch, float* roll)
{
    *pitch = __pitch;
    *roll = __roll;
}

void Platform::swapBuffers()
{
    if (__view)
        CGLFlushDrawable((CGLContextObj)[[__view openGLContext] CGLContextObj]);
}

}

#endif
