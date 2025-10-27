// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * Secret Mode "Anti‑Stress" — Zama FHEVM
 * --------------------------------------
 * A user privately submits heart rate (BPM) and stress minutes from their watch.
 * The contract returns ONLY a binary flag:
 *   1 = break is MANDATORY
 *   0 = break is OPTIONAL
 * No biometrics are revealed on-chain; only the flag handle is exposed.
 *
 * Requirements implemented:
 *  - Uses ONLY the official Zama Solidity library.
 *  - No FHE operations inside view/pure functions.
 *  - Access control via FHE.allow / FHE.allowThis.
 *  - Option for private or publicly-decryptable flag (both variants provided).
 */

import { FHE, ebool, euint16, externalEuint16 } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract AntiStressMode is SepoliaConfig {
    /* ───────── Ownable ───────── */
    address public owner;
    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor() { owner = msg.sender; }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        owner = newOwner;
    }

    /* ───────── Policy ───────── */
    /**
     * Decision policy:
     *  - If mode = 0 (OR):  mandatory = (bpm >= BPM_THR) OR (stressMin >= STRESS_THR)
     *  - If mode = 1 (AND): mandatory = (bpm >= BPM_THR) AND (stressMin >= STRESS_THR)
     */
    struct Policy { uint16 bpmThreshold; uint16 stressMinThreshold; uint8 mode; }
    Policy public policy;

    event PolicyUpdated(uint16 bpmThreshold, uint16 stressMinThreshold, uint8 mode);

    /** Default policy: BPM >= 100 OR Stress >= 15min → mandatory */
    function setDefaultPolicy() public onlyOwner {
        policy = Policy({ bpmThreshold: 100, stressMinThreshold: 15, mode: 0 });
        emit PolicyUpdated(policy.bpmThreshold, policy.stressMinThreshold, policy.mode);
    }

    function setPolicy(uint16 bpmThr, uint16 stressMinThr, uint8 mode) external onlyOwner {
        require(mode <= 1, "mode 0=OR, 1=AND");
        require(bpmThr > 0 || stressMinThr > 0, "empty policy");
        policy = Policy({ bpmThreshold: bpmThr, stressMinThreshold: stressMinThr, mode: mode });
        emit PolicyUpdated(bpmThr, stressMinThr, mode);
    }

    /* ───────── Events ───────── */
    event StressChecked(address indexed user, bytes32 decisionHandle, bool isPublic);

    /* ───────── Storage (optional convenience) ───────── */
    // Store the last encrypted decision per user so they can fetch its handle later.
    mapping(address => ebool) private _lastDecision;
    mapping(address => bool)  private _hasDecision;

    /* ───────── Core evaluation (internal) ───────── */
    function _evaluate(externalEuint16 bpmExt, externalEuint16 stressExt, bytes calldata proof)
        internal
        returns (ebool mandatory)
    {
        require(proof.length > 0, "Empty proof");
        require(policy.bpmThreshold > 0 || policy.stressMinThreshold > 0, "Policy not set");

        // 1) Import encrypted inputs (attestation verified internally)
        euint16 bpm    = FHE.fromExternal(bpmExt, proof);
        euint16 stress = FHE.fromExternal(stressExt, proof);

        // 2) Compare against plaintext thresholds
        ebool bpmHigh    = FHE.ge(bpm,    FHE.asEuint16(policy.bpmThreshold));
        ebool stressHigh = FHE.ge(stress, FHE.asEuint16(policy.stressMinThreshold));

        // 3) Combine according to mode (plaintext branch)
        if (policy.mode == 0) {
            // OR
            mandatory = FHE.or(bpmHigh, stressHigh);
        } else {
            // AND
            mandatory = FHE.and(bpmHigh, stressHigh);
        }

        // 4) ACL for subsequent reads / user decryption
        FHE.allowThis(mandatory);
        FHE.allow(mandatory, msg.sender);

        // 5) Persist last decision handle for convenience
        _lastDecision[msg.sender] = mandatory;
        _hasDecision[msg.sender] = true;
    }

    /* ───────── Public methods ───────── */

    /**
     * @notice Private result: only the caller can decrypt via userDecrypt(...).
     * @return decisionCt ebool ciphertext — 1 = mandatory, 0 = optional
     */
    function checkStressPrivate(
        externalEuint16 bpmExt,
        externalEuint16 stressMinExt,
        bytes calldata proof
    ) external returns (ebool decisionCt) {
        decisionCt = _evaluate(bpmExt, stressMinExt, proof);
        emit StressChecked(msg.sender, FHE.toBytes32(decisionCt), false);
    }

    /**
     * @notice Public result: mark the flag as publicly decryptable (no biometrics revealed).
     * @dev Useful for dashboards that need a clear yes/no without user signature.
     */
    function checkStressPublic(
        externalEuint16 bpmExt,
        externalEuint16 stressMinExt,
        bytes calldata proof
    ) external returns (ebool decisionCt) {
        decisionCt = _evaluate(bpmExt, stressMinExt, proof);
        FHE.makePubliclyDecryptable(decisionCt);
        emit StressChecked(msg.sender, FHE.toBytes32(decisionCt), true);
    }

    /* ───────── View helpers (no FHE ops) ───────── */

    /** Return the handle of the caller's last decision (if any). */
    function getMyLastDecisionHandle() external view returns (bytes32) {
        return _hasDecision[msg.sender] ? FHE.toBytes32(_lastDecision[msg.sender]) : bytes32(0);
    }

    function hasDecision(address user) external view returns (bool) { return _hasDecision[user]; }

    function version() external pure returns (string memory) { return "AntiStressMode/1.0.0"; }
}
