// Sync.swift
// Rocket-sync track data ported from the original sync.cpp
// Row = floor(position / 20840) where position = t * 44100

import Darwin

// ─── Track keyframe ──────────────────────────────────────────────────────────
struct TrackKey {
    var row: Int
    var value: Float
    var interp: Int  // 0 = stepped, 1 = linear
}

// ─── Sync interpolation ───────────────────────────────────────────────────────
func syncParam(_ position: Int, _ track: [TrackKey]) -> Float {
    let ro = Float(position) / Float(20840)
    let ir = floorf(ro)
    let iri = Int(ir)
    var r = 0
    while r < 100 {
        if track[r].row >= iri { break }
        r += 1
    }
    if r > 0 { r -= 1 }
    if track[r].interp == 0 { return track[r].value }
    return track[r].value + (track[r+1].value - track[r].value) * (ro - Float(track[r].row)) / Float(track[r+1].row - track[r].row)
}

// ─── Sync data ────────────────────────────────────────────────────────────────
enum Sync {
    static let camSeedX: [TrackKey] = [
        .init(row:0,value:98,interp:0),.init(row:16,value:5,interp:0),.init(row:32,value:17,interp:0),
        .init(row:44,value:113,interp:0),.init(row:56,value:108,interp:0),.init(row:62,value:18,interp:0),
        .init(row:72,value:9,interp:0),.init(row:80,value:105,interp:0),.init(row:88,value:6,interp:0),
        .init(row:92,value:101,interp:0),.init(row:104,value:186,interp:0),.init(row:120,value:12,interp:0),
        .init(row:140,value:81,interp:0),.init(row:150,value:98,interp:0),.init(row:168,value:153,interp:0),
        .init(row:196,value:114,interp:0),.init(row:212,value:48,interp:0),.init(row:228,value:83,interp:0),
        .init(row:260,value:11,interp:0),.init(row:268,value:8,interp:0),.init(row:276,value:22,interp:0),
        .init(row:292,value:11,interp:0),.init(row:308,value:3,interp:0),.init(row:328,value:9,interp:0),
        .init(row:344,value:50,interp:0),.init(row:360,value:1,interp:0),.init(row:392,value:125,interp:0),
        .init(row:512,value:0,interp:0)]

    static let camSeedY: [TrackKey] = [
        .init(row:0,value:0,interp:0),.init(row:150,value:1,interp:0),.init(row:308,value:0,interp:0),
        .init(row:344,value:1,interp:0),.init(row:360,value:0,interp:0),
        .init(row:512,value:0,interp:0)]

    static let camSpeed: [TrackKey] = [
        .init(row:0,value:1,interp:0),.init(row:92,value:5,interp:0),.init(row:104,value:4,interp:0),
        .init(row:140,value:24,interp:0),.init(row:150,value:58,interp:0),.init(row:168,value:87,interp:0),
        .init(row:196,value:255,interp:0),.init(row:228,value:188,interp:0),.init(row:260,value:255,interp:0),
        .init(row:292,value:16,interp:0),.init(row:308,value:64,interp:0),.init(row:328,value:179,interp:0),
        .init(row:360,value:226,interp:0),.init(row:392,value:30,interp:0),
        .init(row:512,value:0,interp:0)]

    static let camFov: [TrackKey] = [
        .init(row:0,value:53,interp:0),.init(row:16,value:160,interp:0),.init(row:26,value:8,interp:0),
        .init(row:62,value:4,interp:0),.init(row:75,value:2,interp:0),.init(row:80,value:20,interp:0),
        .init(row:83,value:12,interp:0),.init(row:88,value:8,interp:0),.init(row:92,value:60,interp:0),
        .init(row:120,value:24,interp:0),.init(row:140,value:18,interp:0),.init(row:150,value:28,interp:0),
        .init(row:168,value:48,interp:0),.init(row:196,value:160,interp:0),.init(row:212,value:120,interp:0),
        .init(row:228,value:64,interp:0),.init(row:260,value:128,interp:0),.init(row:292,value:53,interp:0),
        .init(row:328,value:120,interp:0),
        .init(row:512,value:0,interp:0)]

    static let camPosY: [TrackKey] = [
        .init(row:0,value:4,interp:0),.init(row:16,value:128,interp:0),.init(row:26,value:9,interp:0),
        .init(row:32,value:4,interp:0),.init(row:44,value:5,interp:0),.init(row:72,value:14,interp:0),
        .init(row:88,value:32,interp:0),.init(row:92,value:8,interp:0),.init(row:140,value:80,interp:0),
        .init(row:150,value:140,interp:0),.init(row:168,value:16,interp:0),.init(row:196,value:8,interp:0),
        .init(row:268,value:4,interp:0),.init(row:276,value:16,interp:0),.init(row:300,value:48,interp:0),
        .init(row:308,value:190,interp:0),.init(row:328,value:14,interp:0),.init(row:344,value:20,interp:0),
        .init(row:360,value:14,interp:0),
        .init(row:512,value:0,interp:0)]

    static let camTarY: [TrackKey] = [
        .init(row:0,value:32,interp:0),.init(row:16,value:255,interp:0),.init(row:26,value:128,interp:0),
        .init(row:72,value:127,interp:0),.init(row:88,value:128,interp:0),.init(row:140,value:106,interp:0),
        .init(row:150,value:108,interp:0),.init(row:168,value:115,interp:0),.init(row:196,value:128,interp:0),
        .init(row:268,value:200,interp:0),.init(row:276,value:128,interp:0),.init(row:300,value:111,interp:0),
        .init(row:308,value:80,interp:0),.init(row:344,value:100,interp:0),.init(row:360,value:120,interp:0),
        .init(row:512,value:0,interp:0)]

    static let sunAngle: [TrackKey] = [
        .init(row:0,value:64,interp:0),.init(row:26,value:90,interp:0),.init(row:32,value:32,interp:0),
        .init(row:62,value:56,interp:0),.init(row:72,value:160,interp:0),.init(row:80,value:64,interp:0),
        .init(row:88,value:160,interp:0),.init(row:92,value:180,interp:0),.init(row:104,value:140,interp:0),
        .init(row:120,value:165,interp:0),.init(row:140,value:110,interp:0),.init(row:150,value:80,interp:0),
        .init(row:168,value:105,interp:0),.init(row:196,value:50,interp:0),.init(row:228,value:10,interp:0),
        .init(row:260,value:150,interp:0),.init(row:276,value:85,interp:0),.init(row:292,value:64,interp:0),
        .init(row:308,value:170,interp:0),.init(row:328,value:100,interp:0),.init(row:344,value:170,interp:0),
        .init(row:360,value:0,interp:0),.init(row:392,value:35,interp:0),
        .init(row:512,value:0,interp:0)]

    static let terWaterLevel: [TrackKey] = [
        .init(row:0,value:154,interp:0),.init(row:26,value:200,interp:0),.init(row:32,value:0,interp:0),
        .init(row:72,value:170,interp:0),.init(row:92,value:0,interp:0),.init(row:168,value:120,interp:0),
        .init(row:196,value:160,interp:0),.init(row:212,value:40,interp:0),.init(row:308,value:180,interp:0),
        .init(row:344,value:0,interp:0),.init(row:360,value:193,interp:0),.init(row:392,value:170,interp:0),
        .init(row:512,value:0,interp:0)]

    static let terSeason: [TrackKey] = [
        .init(row:0,value:0,interp:0),.init(row:292,value:0,interp:1),.init(row:300,value:64,interp:1),
        .init(row:308,value:128,interp:1),.init(row:322,value:255,interp:0),.init(row:392,value:255,interp:1),
        .init(row:424,value:0,interp:0),
        .init(row:512,value:0,interp:0)]

    static let imgBrightness: [TrackKey] = [
        .init(row:0,value:0,interp:1),.init(row:8,value:128,interp:0),.init(row:26,value:110,interp:0),
        .init(row:62,value:32,interp:0),.init(row:72,value:90,interp:0),.init(row:92,value:110,interp:0),
        .init(row:120,value:128,interp:0),.init(row:140,value:90,interp:0),.init(row:160,value:90,interp:1),
        .init(row:167,value:0,interp:0),.init(row:168,value:128,interp:0),.init(row:196,value:120,interp:0),
        .init(row:228,value:105,interp:0),.init(row:250,value:105,interp:1),.init(row:251,value:128,interp:0),
        .init(row:260,value:100,interp:0),.init(row:308,value:24,interp:0),.init(row:328,value:120,interp:0),
        .init(row:360,value:110,interp:0),.init(row:392,value:100,interp:0),.init(row:424,value:100,interp:1),
        .init(row:448,value:0,interp:0),
        .init(row:512,value:0,interp:0)]

    static let imgContrast: [TrackKey] = [
        .init(row:0,value:150,interp:0),.init(row:62,value:250,interp:0),.init(row:72,value:180,interp:0),
        .init(row:92,value:0,interp:1),.init(row:102,value:160,interp:0),.init(row:120,value:128,interp:0),
        .init(row:140,value:190,interp:0),.init(row:160,value:190,interp:1),.init(row:167,value:130,interp:0),
        .init(row:168,value:160,interp:0),.init(row:196,value:140,interp:0),.init(row:228,value:180,interp:0),
        .init(row:292,value:0,interp:1),.init(row:293,value:190,interp:0),.init(row:308,value:255,interp:0),
        .init(row:328,value:150,interp:0),.init(row:360,value:170,interp:0),.init(row:392,value:180,interp:0),
        .init(row:424,value:180,interp:1),.init(row:448,value:128,interp:0),
        .init(row:512,value:0,interp:0)]

    static let terScale: [TrackKey] = [
        .init(row:0,value:200,interp:0),.init(row:26,value:140,interp:0),.init(row:32,value:200,interp:0),
        .init(row:120,value:255,interp:0),.init(row:260,value:220,interp:0),.init(row:292,value:255,interp:0),
        .init(row:328,value:20,interp:0),.init(row:360,value:230,interp:0),
        .init(row:512,value:0,interp:0)]
}
