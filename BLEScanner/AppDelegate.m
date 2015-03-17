//
//  AppDelegate.m
//  BLEScanner
//
//  Created by Liam Nichols on 16/11/2013.
//  Copyright (c) 2013 Liam Nichols. All rights reserved.
//

@import IOBluetooth;

#import "AppDelegate.h"
#import <CoreLocation/CoreLocation.h>
#import <WebKit/WebKit.h>

static const NSTimeInterval kScanTimeInterval = 1.0;

@interface AppDelegate () <CBCentralManagerDelegate, CBPeripheralDelegate, CLLocationManagerDelegate>

@property (nonatomic, strong) CBCentralManager *manager;
@property (nonatomic, strong) CLLocationManager *locationManager;

@property (nonatomic, strong) NSMutableArray *beacons;
@property (nonatomic, strong) NSMutableDictionary *foundBeacons;

@property (weak) IBOutlet WebView *webViewer;
@property (nonatomic) BOOL canScan;
@property (nonatomic) BOOL isScanning;
@property (nonatomic) NSString *exportFilePath;

@property (nonatomic, strong) NSTimer *scanTimer;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    self.manager = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:nil];
    // Turn on CoreLocation
    _locationManager = [[CLLocationManager alloc] init];
    _locationManager.delegate = self;
    [_locationManager startUpdatingLocation];
    
    _exportFilePath = [NSHomeDirectory() stringByAppendingPathComponent:@"ibeacons.csv"];
}

-(void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    if (self.manager.state == CBCentralManagerStatePoweredOn)
    {
        self.canScan = YES;
    }
    else
    {
        self.canScan = NO;
    }
    
    switch (central.state)
    {
        case CBCentralManagerStatePoweredOff:
            [self.statusLabel setStringValue:@"Powered Off"];
            break;
        case CBCentralManagerStatePoweredOn:
            [self.statusLabel setStringValue:@"Powered On"];
            break;
        case CBCentralManagerStateResetting:
            [self.statusLabel setStringValue:@"Resetting"];
            break;
        case CBCentralManagerStateUnauthorized:
            [self.statusLabel setStringValue:@"Unauthorised"];
            break;
        case CBCentralManagerStateUnsupported:
            [self.statusLabel setStringValue:@"Unsupported"];
            break;
        case CBCentralManagerStateUnknown:
        default:
            [self.statusLabel setStringValue:@"Unknown"];
            break;
    }
}

-(void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI
{
    NSData *advData = [advertisementData objectForKey:@"kCBAdvDataManufacturerData"];
    if ([self advDataIsBeacon:advData])
    {
        NSMutableDictionary *beacon = [NSMutableDictionary dictionaryWithDictionary:[self getBeaconInfoFromData:advData]];
        
        //rssi
        [beacon setObject:RSSI forKey:@"RSSI"];

        //peripheral uuid
        [beacon setObject:peripheral.identifier.UUIDString forKey:@"deviceUUID"];
        
        //distance
        NSNumber *distance = [self calculatedDistance:[beacon objectForKey:@"power"] RSSI:RSSI];
        if (distance) {
            [beacon setObject:distance forKey:@"distance"];
        }
        
        //proximity
        [beacon setObject:[self proximityFromDistance:distance] forKey:@"proximity"];
        
        //combined uuid
        NSString *uniqueUUID = peripheral.identifier.UUIDString;
        NSString *beaconUUID = beacon[@"uuid"];
        
        //location
        NSString *location = [NSString stringWithFormat:@"%f,%f", _locationManager.location.coordinate.latitude, _locationManager.location.coordinate.longitude];
        
        //NSLog(@"location: %@", location);
        [beacon setObject:location forKey:@"location"];
        
        if (beaconUUID) {
            uniqueUUID = [uniqueUUID stringByAppendingString:beaconUUID];
        }

        //add to beacon dictionary
        [self.foundBeacons setObject:beacon forKey:uniqueUUID];
    }
}

//algorythm taken from http://stackoverflow.com/a/20434019/814389
//I've seen this method mentioned a couple of times but cannot verify its accuracy
- (NSNumber *)calculatedDistance:(NSNumber *)txPowerNum RSSI:(NSNumber *)RSSINum
{
    int txPower = [txPowerNum intValue];
    double rssi = [RSSINum doubleValue];
    
    if (rssi == 0) {
        return nil; // if we cannot determine accuracy, return nil.
    }
    
    double ratio = rssi * 1.0 / txPower;
    if (ratio < 1.0) {
        return @(pow(ratio, 10.0));
    }
    else {
        double accuracy =  (0.89976) * pow(ratio, 7.7095) + 0.111;
        return @(accuracy);
    }
}

- (BOOL)advDataIsBeacon:(NSData *)data
{
    //TODO: could this be cleaner?
    Byte expectingBytes [4] = { 0x4c, 0x00, 0x02, 0x15 };
    NSData *expectingData = [NSData dataWithBytes:expectingBytes length:sizeof(expectingBytes)];
    
    if (data.length > expectingData.length)
    {
        if ([[data subdataWithRange:NSMakeRange(0, expectingData.length)] isEqual:expectingData])
        {
            return YES;
        }
    }
    
    return NO;
}

- (NSDictionary *)getBeaconInfoFromData:(NSData *)data
{
    NSRange uuidRange = NSMakeRange(4, 16);
    NSRange majorRange = NSMakeRange(20, 2);
    NSRange minorRange = NSMakeRange(22, 2);
    NSRange powerRange = NSMakeRange(24, 1);
    
    Byte uuidBytes[16];
    [data getBytes:&uuidBytes range:uuidRange];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:uuidBytes];
    
    uint16_t majorBytes;
    [data getBytes:&majorBytes range:majorRange];
    uint16_t majorBytesBig = (majorBytes >> 8) | (majorBytes << 8);
    
    uint16_t minorBytes;
    [data getBytes:&minorBytes range:minorRange];
    uint16_t minorBytesBig = (minorBytes >> 8) | (minorBytes << 8);
    
    int8_t powerByte;
    [data getBytes:&powerByte range:powerRange];
    
    return @{ @"uuid" : uuid.UUIDString, @"major" : @(majorBytesBig), @"minor" : @(minorBytesBig), @"power" : @(powerByte) };
}

#pragma mark - Scanning

- (BOOL)startScanning
{
    if (self.canScan)
    {
        if (self.scanTimer)
            [self.scanTimer invalidate];
        
        NSTimeInterval duration = self.durationTextField.doubleValue;
        if (duration == 0)
        {
            duration = kScanTimeInterval;
            [self.durationTextField setDoubleValue:kScanTimeInterval];
        }
        

        if (self.repeatCheckbox.state == NSOffState)
        {
            self.beacons = nil;
            [self.tableView reloadData];
        }
        
        self.isScanning = YES;
        
        [self.manager scanForPeripheralsWithServices:nil options:nil];
        
        self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:duration target:self selector:@selector(timerDidFire) userInfo:nil repeats:NO];
        
        NSLog(@"started scanning");
        return YES;
    }
    NSLog(@"unable to start scan");
    return NO;
}

- (void)stopScanning
{
    [self.manager stopScan];
    self.isScanning = NO;
    [self.scanTimer invalidate];
}

- (void)timerDidFire
{
    NSLog(@"found beacons during scan: %@",[self.foundBeacons allValues]);
    self.beacons = [[self.foundBeacons allValues] mutableCopy];
    [self.beacons sortUsingDescriptors:self.tableView.sortDescriptors];
    
    //[self.foundBeacons removeAllObjects];
    [self stopScanning];
    
    if (self.repeatCheckbox.state != NSOffState)
    {
        [self startScanning];
    }
    
    [self.tableView reloadData];
}

#pragma mark - Button Updating

-(void)setIsScanning:(BOOL)isScanning
{
    if (_isScanning != isScanning)
    {
        _isScanning = isScanning;
        
        if (isScanning)
        {
            [self.durationTextField setEnabled:NO];
            self.scanButton.title = @"Stop Scanning";
            self.scanButton.target = self;
            self.scanButton.action = @selector(stopScanning);
            [self.repeatCheckbox setEnabled:NO];
        }
        else if (self.canScan)
        {
            [self.durationTextField setEnabled:YES];
            self.scanButton.title = @"Start Scanning";
            self.scanButton.target = self;
            self.scanButton.action = @selector(startScanning);
            [self.repeatCheckbox setEnabled:YES];
        }
        else if (!self.canScan)
        {
            [self.durationTextField setEnabled:YES];
            self.scanButton.title = @"Start Scanning";
            self.scanButton.target = nil;
            self.scanButton.action = nil;
            [self.repeatCheckbox setEnabled:YES];
        }
    }
}

-(void)setCanScan:(BOOL)canScan
{
    if (_canScan != canScan)
    {
        _canScan = canScan;
        
        if (canScan)
        {
            [self.scanButton setEnabled:YES];
            [self.scanButton setTitle:@"Start Scanning"];
            [self.scanButton setTarget:self];
            [self.scanButton setAction:@selector(startScanning)];
            [self.repeatCheckbox setEnabled:YES];
        }
        else
        {
            [self.scanButton setEnabled:NO];
            [self.scanButton setTitle:@"Start Scanning"];
            [self.scanButton setTarget:self];
            [self.scanButton setAction:@selector(startScanning)];
            [self.repeatCheckbox setEnabled:NO];
        }
    }
}

#pragma mark - Lazy Loading

-(NSMutableDictionary *)foundBeacons
{
    if (!_foundBeacons) {
        _foundBeacons = [NSMutableDictionary new];
    }
    return _foundBeacons;
}

#pragma mark NSTableView

-(NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return self.beacons.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    
    // get an existing cell with the MyView identifier if it exists
    NSTextField *result = [tableView makeViewWithIdentifier:@"MyView" owner:self];
    
    // There is no existing cell to reuse so we will create a new one
    if (result == nil) {
        
        result = [[NSTextField alloc] initWithFrame:CGRectZero];
        [result setBordered:NO];
        [result setSelectable:NO];
        [result setBackgroundColor:[NSColor clearColor]];
        [result setAlignment:NSCenterTextAlignment];
        [result setIdentifier:@"MyView"];
        [result setEditable:NO];
        [result setSelectable:YES];
    }
    
    NSDictionary *beacon = [self.beacons objectAtIndex:row];
    if ([tableColumn.identifier isEqualToString:@"devuuid"])
        result.stringValue = [beacon objectForKey:@"deviceUUID"];
    
    if ([tableColumn.identifier isEqualToString:@"uuid"])
        result.stringValue = [beacon objectForKey:@"uuid"];
    
    if ([tableColumn.identifier isEqualToString:@"major"])
        result.stringValue = [[beacon objectForKey:@"major"] stringValue];
    
    if ([tableColumn.identifier isEqualToString:@"minor"])
        result.stringValue = [[beacon objectForKey:@"minor"] stringValue];
    
    if ([tableColumn.identifier isEqualToString:@"power"])
        result.stringValue = [self decibelStringFromNumber:[beacon objectForKey:@"power"]];
    
    if ([tableColumn.identifier isEqualToString:@"rssi"])
        result.stringValue = [self decibelStringFromNumber:[beacon objectForKey:@"RSSI"]];
    
    if ([tableColumn.identifier isEqualToString:@"distance"])
        result.stringValue = [self distanceStringFromNumber:[beacon objectForKey:@"distance"]];
    
    if ([tableColumn.identifier isEqualToString:@"proximity"])
        result.stringValue = [beacon objectForKey:@"proximity"];
    
    if ([tableColumn.identifier isEqualToString:@"location"])
        result.stringValue = [beacon objectForKey:@"location"];
    
    
    // return the result.
    return result;
    
}

- (NSString *)decibelStringFromNumber:(NSNumber *)dbVal
{
    return [NSString stringWithFormat:@"%idB",[dbVal intValue]];
}

- (NSString *)distanceStringFromNumber:(NSNumber *)distance
{
    if (distance) {
        return [NSString stringWithFormat:@"%.2fm",[distance doubleValue]];
    }
    return @"-";
}

- (NSString *)proximityFromDistance:(NSNumber *)distance
{
    if (distance == nil) {
        distance = @(-1);
    }
    
    if (distance.doubleValue >= 2.0)
        return @"Far";
    if (distance.doubleValue >= 0.25)
        return @"Near";
    if (distance.doubleValue >= 0)
        return @"immediate";
    return @"Unknown";
}

- (void)tableView:(NSTableView *)tableView
    didAddRowView:(NSTableRowView *)rowView
           forRow:(NSInteger)row {
    
    if (row % 2 == 1) {
        [rowView setBackgroundColor:[NSColor colorWithWhite:0.9294117647 alpha:1.0]];
    }
    
}

-(void)tableView:(NSTableView *)tableView sortDescriptorsDidChange: (NSArray *)oldDescriptors
{
    NSArray *newDescriptors = [tableView sortDescriptors];

    [self.beacons sortUsingDescriptors:newDescriptors];

    [tableView reloadData];
}

- (void)locationManager:(CLLocationManager *)manager
    didUpdateToLocation:(CLLocation *)newLocation
           fromLocation:(CLLocation *)oldLocation
{
    // Ignore updates where nothing we care about changed
    if (newLocation.coordinate.longitude == oldLocation.coordinate.longitude &&
        newLocation.coordinate.latitude == oldLocation.coordinate.latitude &&
        newLocation.horizontalAccuracy == oldLocation.horizontalAccuracy)
    {
        return;
    }
    
    [self.locationLabel setStringValue:[NSString stringWithFormat:@"Lat: \t\t%f\nLon: \t%f\nAcc: \t%.02fm", newLocation.coordinate.latitude, newLocation.coordinate.longitude, newLocation.horizontalAccuracy]];
    
    
    // Load the HTML for displaying the Google map from a file and replace the
    // format placeholders with our location data
    
    NSString *htmlString = [NSString stringWithFormat:
                            [NSString
                             stringWithContentsOfFile:
                             [[NSBundle mainBundle]
                              pathForResource:@"HTMLFormatString" ofType:@"html"]
                             encoding:NSUTF8StringEncoding
                             error:NULL],
                            newLocation.coordinate.latitude,
                            newLocation.coordinate.longitude,
                            [AppDelegate latitudeRangeForLocation:newLocation],
                            [AppDelegate longitudeRangeForLocation:newLocation]];
    
    //NSLog(@"HTML String: %@", htmlString);
    // Load the HTML in the WebView and set the labels
    [[_webViewer mainFrame] loadHTMLString:htmlString baseURL:nil];
    //[_locationLabel setStringValue:[NSString stringWithFormat:@"%f, %f",
    //                               newLocation.coordinate.latitude, newLocation.coordinate.longitude]];
    //[accuracyLabel setStringValue:[NSString stringWithFormat:@"%f",
    //                               newLocation.horizontalAccuracy]];
     
}

- (void)locationManager:(CLLocationManager *)manager
       didFailWithError:(NSError *)error
{
    [[_webViewer mainFrame]
     loadHTMLString:
     [NSString stringWithFormat:
      NSLocalizedString(@"Location manager failed with error: %@", nil),
      [error localizedDescription]]
     baseURL:nil];
    [_locationLabel setStringValue:@""];
}

+ (double)latitudeRangeForLocation:(CLLocation *)aLocation
{
    const double M = 6367000.0; // mean meridional radius of curvature of Earth
    const double metersToLatitude = 1.0 / ((M_PI / 180.0) * M);
    const double accuracyToWindowScale = 2.0;
    
    return aLocation.horizontalAccuracy * metersToLatitude * accuracyToWindowScale;
}

+ (double)longitudeRangeForLocation:(CLLocation *)aLocation
{
    double latitudeRange = [self latitudeRangeForLocation:aLocation];
    
    return latitudeRange * cos(aLocation.coordinate.latitude * M_PI / 180.0);
}

- (IBAction)saveAsFileAction:(id)sender {
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:[self exportFilePath]]) {
        [[NSFileManager defaultManager] createFileAtPath: [self exportFilePath] contents:nil attributes:nil];
        NSLog(@"Route creato");
    }
    
    NSMutableString *writeString = [NSMutableString stringWithCapacity:0]; //don't worry about the capacity, it will expand as necessary
    [writeString appendString:[NSString stringWithFormat:@"Device UUID, UUID, Major, Minor, Latitude, Longitude\n"]];
    
    for (int i=0; i< [_beacons count]; i++) {
        [writeString appendString:
                       [NSString stringWithFormat: @"%@,%@,%@,%@,%@\n", [[self.beacons objectAtIndex:i] objectForKey:@"deviceUUID"],
                        [[self.beacons objectAtIndex:i] objectForKey:@"uuid"],
                        [[self.beacons objectAtIndex:i] objectForKey:@"major"],
                        [[self.beacons objectAtIndex:i] objectForKey:@"minor"],
                        [[self.beacons objectAtIndex:i] objectForKey:@"location"]]
                       ];
    }
    
    /*
    for (int i=0; i<[_foundBeacons count]; i++) {
        writeString = [writeString appendString:[NSString stringWithFormat:@"%@, %@, %@, %@, %0.2f, \n",[[ [beacon objectForKey:@"deviceUUID"]:i]dates],[[dataArray objectAtIndex:i] time],[[dataArray objectAtIndex:i] category],[[dataArray objectAtIndex:i]place],[[dataArray objectAtIndex:i] amount]]]; //the \n will put a newline in
    }
     */
    
    
    //Moved this stuff out of the loop so that you write the complete string once and only once.
    //NSLog(@"writeString :%@",writeString);
    
    NSFileHandle *handle;
    handle = [NSFileHandle fileHandleForWritingAtPath: [self exportFilePath] ];
    //say to handle where's the file fo write
    [handle truncateFileAtOffset:[handle seekToEndOfFile]];
    //position handle cursor to the end of file
    [handle writeData:[writeString dataUsingEncoding:NSUTF8StringEncoding]];
}

-(BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
        return YES;
}



@end
