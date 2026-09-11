import XCTest
@testable import PianobarCore

/// Covers how pianobar's `pRet` / `wRet` result codes are turned into events,
/// and the station-mutation events that used to be dropped entirely.
final class EventParserResultCodeTests: XCTestCase {

    // MARK: - Login vs. transport failure

    func testLoginFailureAtTransportLayerIsAnAuthFailureNotANetworkBlip() {
        // A sign-in that can't reach Pandora used to fall through the generic
        // wRet check and report as `.networkError`, whose banner auto-clears —
        // leaving the app looking healthy while unauthenticated, and never
        // routing back to the login screen.
        let payload = """
        pRet=1
        pRetStr=Everything is fine :)
        wRet=6
        wRetStr=Couldn't resolve host name
        """
        guard case .userLogin(let result) =
                EventParser.parse(eventType: "userlogin", payload: payload)
        else { return XCTFail("expected .userLogin") }
        XCTAssertEqual(result.failure, .network,
                       "a transport failure must not be reported as bad credentials")
        XCTAssertEqual(result.message, "Couldn't resolve host name")
    }

    func testLoginFailureFromPandoraCarriesItsMessage() {
        let payload = """
        pRet=13
        pRetStr=Invalid login
        wRet=0
        wRetStr=OK
        """
        guard case .userLogin(let result) =
                EventParser.parse(eventType: "userlogin", payload: payload)
        else { return XCTFail("expected .userLogin") }
        XCTAssertEqual(result.failure, .credentials)
        XCTAssertEqual(result.message, "Invalid login")
    }

    func testSuccessfulLogin() {
        let payload = "pRet=1\npRetStr=Everything is fine :)\nwRet=0\nwRetStr=OK"
        XCTAssertEqual(
            EventParser.parse(eventType: "userlogin", payload: payload),
            .userLogin(LoginResult(failure: nil, message: "Everything is fine :)")))
    }

    // MARK: - Pandora-side errors

    func testPandoraErrorOnANonLoginEventIsSurfaced() {
        // Only `wRet` was ever checked, so Pandora-side failures like this
        // vanished silently instead of reaching the error banner.
        let payload = """
        pRet=1037
        pRetStr=Station limit reached
        wRet=0
        wRetStr=OK
        """
        XCTAssertEqual(
            EventParser.parse(eventType: "stationcreate", payload: payload),
            .pandoraError(code: 1037, message: "Station limit reached"))
    }

    func testNetworkErrorStillWinsOverPandoraCode() {
        let payload = "pRet=1\nwRet=7\nwRetStr=Failed to connect"
        XCTAssertEqual(
            EventParser.parse(eventType: "songstart", payload: payload),
            .networkError(message: "Failed to connect"))
    }

    func testMissingResultCodesAreTreatedAsSuccess() {
        // Not every payload carries pRet/wRet; absence must not read as failure.
        let payload = "title=T\nartist=A"
        guard case .songStart = EventParser.parse(eventType: "songstart", payload: payload)
        else { return XCTFail("expected .songStart") }
    }

    // MARK: - Station mutations

    func testStationMutationsCarryTheFullStationList() {
        // pianobar dumps the whole `station<N>=` list on these events, so each
        // one is an authoritative refresh. Previously they hit `default: nil`
        // and the sidebar went stale — which also desynced the array indices
        // that station commands are addressed by.
        let payload = """
        station0=Radio A
        station1=Radio B
        station2=Brand New Radio
        pRet=1
        wRet=0
        """
        for eventType in ["stationcreate", "stationrename",
                          "stationaddmusic", "usergetstations"] {
            guard case .stationsChanged(let stations) =
                    EventParser.parse(eventType: eventType, payload: payload)
            else { return XCTFail("expected .stationsChanged for \(eventType)") }
            XCTAssertEqual(stations.map(\.name), ["Radio A", "Radio B", "Brand New Radio"],
                           "wrong list for \(eventType)")
        }
    }

    /// pianobar builds the event payload from its station list as it stands
    /// when the event fires, which for a delete still contains the station
    /// being removed. Publishing it put the deleted station straight back into
    /// the sidebar, so this event deliberately carries no list.
    func testStationDeleteDoesNotRepublishAStaleList() {
        let payload = """
        station0=Radio A
        station1=Doomed Radio
        station2=Radio B
        pRet=1
        wRet=0
        """
        XCTAssertEqual(
            EventParser.parse(eventType: "stationdelete", payload: payload),
            .stationDeleted)
    }

    func testStationEventWithoutAListIsIgnored() {
        // Don't publish an empty list and blank the sidebar.
        XCTAssertNil(EventParser.parse(eventType: "stationcreate", payload: "pRet=1\nwRet=0"))
    }
}
