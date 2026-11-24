#include "proxy_plugin.h"

#include <windows.h>
#include <WinInet.h>
#include <Ras.h>
#include <RasError.h>

#include <algorithm>
#include <map>
#include <string>
#include <vector>
#include <flutter/standard_method_codec.h>

#pragma comment(lib, "wininet")
#pragma comment(lib, "Rasapi32")

namespace {
struct Settings {
  DWORD flags = PROXY_TYPE_DIRECT;
  std::wstring server, bypass, pac;
};

struct Claim {
  Settings before, applied;
};

std::map<std::wstring, Claim> claims;

std::wstring wide(const std::string& value) {
  if (value.empty()) return {};
  int count = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(count, L'\0');
  if (count) MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), &result[0], count);
  return result;
}

std::string utf8(const std::wstring& value) {
  if (value.empty()) return {};
  int count = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                                  nullptr, 0, nullptr, nullptr);
  std::string result(count, '\0');
  if (count) WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                                 &result[0], count, nullptr, nullptr);
  return result;
}

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableValue encodeSettings(const Settings& s) {
  return EncodableValue(EncodableList{EncodableValue(static_cast<int>(s.flags)),
      EncodableValue(utf8(s.server)), EncodableValue(utf8(s.bypass)), EncodableValue(utf8(s.pac))});
}

Settings decodeSettings(const EncodableValue& encoded) {
  const auto& list = std::get<EncodableList>(encoded);
  return {static_cast<DWORD>(std::get<int>(list.at(0))), wide(std::get<std::string>(list.at(1))),
          wide(std::get<std::string>(list.at(2))), wide(std::get<std::string>(list.at(3)))};
}

bool connections(std::vector<std::wstring>& names) {
  names.emplace_back();  // Default LAN connection.
  RASENTRYNAMEW first{};
  first.dwSize = sizeof(first);
  DWORD bytes = sizeof(first), count = 0;
  DWORD result = RasEnumEntriesW(nullptr, nullptr, &first, &bytes, &count);
  if (result == ERROR_SUCCESS) {
    if (count) names.emplace_back(first.szEntryName);
    return true;
  }
  if (result != ERROR_BUFFER_TOO_SMALL) return false;
  std::vector<RASENTRYNAMEW> entries((bytes + sizeof(first) - 1) / sizeof(first));
  entries.front().dwSize = sizeof(first);
  if (RasEnumEntriesW(nullptr, nullptr, entries.data(), &bytes, &count) != ERROR_SUCCESS) return false;
  for (DWORD i = 0; i < count; ++i) names.emplace_back(entries[i].szEntryName);
  return true;
}

INTERNET_PER_CONN_OPTION_LISTW options(const std::wstring& name,
                                       INTERNET_PER_CONN_OPTIONW* values,
                                       DWORD count) {
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.pszConnection = name.empty() ? nullptr : const_cast<wchar_t*>(name.c_str());
  list.dwOptionCount = count;
  list.pOptions = values;
  return list;
}

bool readSettings(const std::wstring& name, Settings& settings) {
  INTERNET_PER_CONN_OPTIONW values[4]{};
  // Read the user's configured flags, including automatic detection, even
  // when WinINET's current effective detection state differs.
  values[0].dwOption = INTERNET_PER_CONN_FLAGS_UI;
  values[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  values[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  values[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  auto list = options(name, values, 4);
  DWORD bytes = sizeof(list);
  bool ok = InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &bytes) != FALSE;
  if (ok) {
    settings.flags = values[0].Value.dwValue;
    settings.server = values[1].Value.pszValue ? values[1].Value.pszValue : L"";
    settings.bypass = values[2].Value.pszValue ? values[2].Value.pszValue : L"";
    settings.pac = values[3].Value.pszValue ? values[3].Value.pszValue : L"";
  }
  for (size_t i = 1; i < 4; ++i) GlobalFree(values[i].Value.pszValue);
  return ok;
}

// A manual takeover changes three fields. A restore also reinstates the PAC URL.
bool writeSettings(const std::wstring& name, const Settings& settings, DWORD count) {
  INTERNET_PER_CONN_OPTIONW values[4]{};
  values[0].dwOption = INTERNET_PER_CONN_FLAGS;
  values[0].Value.dwValue = settings.flags;
  values[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  values[1].Value.pszValue = const_cast<wchar_t*>(settings.server.c_str());
  values[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  values[2].Value.pszValue = const_cast<wchar_t*>(settings.bypass.c_str());
  values[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  values[3].Value.pszValue = const_cast<wchar_t*>(settings.pac.c_str());
  auto list = options(name, values, count);
  return InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list)) != FALSE;
}

void refresh() {
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

bool sameRoute(const Settings& left, const Settings& right) {
  return left.flags == right.flags && left.server == right.server && left.pac == right.pac;
}

// Every operation is conditional on the settings the caller journaled.
// Keep an in-process copy for the synchronous WM_ENDSESSION callback.
bool writeConnection(const EncodableMap& arguments) {
  const auto name = wide(std::get<std::string>(arguments.at(EncodableValue("name"))));
  const auto expected = decodeSettings(arguments.at(EncodableValue("expected")));
  const auto value = decodeSettings(arguments.at(EncodableValue("value")));
  Settings current;
  if (!readSettings(name, current) || !sameRoute(current, expected) ||
      current.bypass != expected.bypass) return false;
  if (!sameRoute(value, current) || value.bypass != current.bypass) {
    if (!writeSettings(name, value, 4)) return false;
    refresh();
  }
  auto original = arguments.find(EncodableValue("original"));
  if (original != arguments.end()) claims[name] = {decodeSettings(original->second), value};
  else claims.erase(name);
  return readSettings(name, current) && sameRoute(current, value) && current.bypass == value.bypass;
}

bool restoreClaims(std::map<std::wstring, Claim>& records) {
  bool changed = false;
  for (auto it = records.begin(); it != records.end();) {
    auto& claim = it->second;
    Settings current;
    if (!readSettings(it->first, current)) { ++it; continue; }
    if (sameRoute(current, claim.applied)) {
      Settings before = claim.before;
      if (current.bypass != claim.applied.bypass) before.bypass = current.bypass;
      if (!writeSettings(it->first, before, 4)) { ++it; continue; }
      changed = true;
    }
    it = records.erase(it);
  }
  if (changed) refresh();
  return records.empty();
}

bool startProxy(int port, const flutter::EncodableList& bypass, bool defaultOnly) {
  Settings target;
  target.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
  target.server = L"127.0.0.1:" + std::to_wstring(port);
  target.bypass = L"<local>";
  for (const auto& domain : bypass) {
    target.bypass += L";" + wide(std::get<std::string>(domain));
  }

  std::vector<std::wstring> names;
  if (defaultOnly) names.emplace_back();
  else if (!connections(names)) return false;
  std::map<std::wstring, Settings> beforeWrite;
  for (const auto& name : names) {
    Settings current;
    if (!readSettings(name, current)) return false;
    beforeWrite.emplace(name, current);
  }

  std::map<std::wstring, Claim> writes;
  for (const auto& item : beforeWrite) {
    const auto& name = item.first;
    const auto& previous = item.second;
    if (!writeSettings(name, target, 3)) {
      restoreClaims(writes);
      return false;
    }
    auto applied = target;
    applied.pac = previous.pac;
    Settings observed;
    if (readSettings(name, observed) && observed.server == target.server &&
        (observed.flags & PROXY_TYPE_PROXY)) applied = observed;
    writes.emplace(name, Claim{previous, applied});
  }
  refresh();
  return true;
}

bool stopProxy() {
  std::vector<std::wstring> names;
  if (!connections(names)) return false;
  for (const auto& name : names)
    if (!writeSettings(name, Settings{}, 1)) return false;
  refresh();
  return true;
}
}  // namespace

namespace proxy
{

  // static
  void ProxyPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar)
  {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "proxy",
            &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<ProxyPlugin>(registrar);

    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto &call, auto result)
        {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  ProxyPlugin::ProxyPlugin(flutter::PluginRegistrarWindows *registrar)
      : registrar(registrar) {
    window_proc_id = registrar->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
          return HandleWindowProc(hwnd, message, wparam, lparam);
        });
  }

  ProxyPlugin::~ProxyPlugin() {
    if (registrar && window_proc_id != -1) {
      registrar->UnregisterTopLevelWindowProcDelegate(window_proc_id);
    }
  }

  std::optional<LRESULT> ProxyPlugin::HandleWindowProc(
      HWND hwnd,
      UINT message,
      WPARAM wparam,
      LPARAM lparam) {
    if (message == WM_ENDSESSION) {
      if (wparam == TRUE) {
        restoreClaims(claims);
      }
    }
    return std::nullopt;
  }

  void ProxyPlugin::HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (method_call.method_name() == "ReadWindowsProxies") {
      std::vector<std::wstring> names;
      EncodableMap snapshots;
      const auto* defaultOnly = method_call.arguments() ? std::get_if<bool>(method_call.arguments()) : nullptr;
      if (defaultOnly && *defaultOnly) names.emplace_back();
      else if (!connections(names)) { result->Error("read", "Cannot enumerate RAS connections"); return; }
      for (const auto& name : names) {
        Settings current;
        if (!readSettings(name, current)) { result->Error("read", "Cannot read WinINET settings"); return; }
        snapshots.emplace(EncodableValue(utf8(name)), encodeSettings(current));
      }
      result->Success(EncodableValue(snapshots));
    }
    else if (method_call.method_name() == "WriteWindowsProxy") {
      result->Success(writeConnection(std::get<EncodableMap>(*method_call.arguments())));
    }
    else if (method_call.method_name() == "ForgetWindowsProxyClaims") {
      claims.clear();
      result->Success();
    }
    else if (method_call.method_name() == "StopDefaultWindowsProxy") {
      const bool ok = writeSettings(L"", Settings{}, 1);
      if (ok) refresh();
      result->Success(ok);
    }
    else if (method_call.method_name().compare("StopProxy") == 0)
    {
      result->Success(stopProxy());
    }
    else if (method_call.method_name().compare("StartProxy") == 0)
    {
      auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      auto port = std::get<int>(arguments->at(flutter::EncodableValue("port")));
      auto bypassDomain = std::get<flutter::EncodableList>(arguments->at(flutter::EncodableValue("bypassDomain")));
      const bool defaultOnly = arguments->count(flutter::EncodableValue("defaultOnly")) != 0;
      result->Success(startProxy(port, bypassDomain, defaultOnly));
    }
    else
    {
      result->NotImplemented();
    }
  }
} // namespace proxy
