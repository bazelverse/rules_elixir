load("//private:mix_payloads.bzl", _MixPayloadsInfo = "MixPayloadsInfo", _mix_payloads = "mix_payloads")

MixPayloadsInfo = _MixPayloadsInfo

def mix_payloads(**kwargs):
    return _mix_payloads(**kwargs)
