rule EICAR_Test_File
{
    meta:
        description = "EICAR standard anti-malware test string (harmless test file, NOT malware)"
        author      = "3014ICT Activity 5 (Chris Grul, s5501035)"
        reference   = "https://www.eicar.org/download-anti-malware-testfile/"
        note        = "Rustinel's Essential pack ships EICAR as an IOC hash set; this YARA string rule is a belt-and-suspenders that also matches the signature when an executable carrying it is started (Rustinel scans on process-start). Keep this file alongside the Essential pack's YARA rules."
    strings:
        // The exact 68-byte EICAR signature. Backslash is escaped for YARA.
        $eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
    condition:
        $eicar
}
