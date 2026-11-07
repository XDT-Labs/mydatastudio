#include "system_trash_channel.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <windows.h>
#include <wrl/client.h>

#include <cstdio>
#include <string>
#include <variant>

namespace {

using Microsoft::WRL::ComPtr;

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                            static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                        static_cast<int>(utf8.size()), utf16.data(), length);
  return utf16;
}

std::string Describe(const char* what, HRESULT hr) {
  char buffer[96];
  std::snprintf(buffer, sizeof(buffer), "%s (HRESULT 0x%08lX)", what,
                static_cast<unsigned long>(hr));
  return buffer;
}

bool IsNotFound(HRESULT hr) {
  return hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
         hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND);
}

// Cancels any delete that would not go to the Recycle Bin. With
// FOFX_RECYCLEONDELETE the shell still deletes permanently when it can't
// recycle (a network share, a file too large for the bin), and FOF_NO_UI
// answers its "delete permanently?" prompt with yes. The user was promised
// something recoverable, so that case is refused instead (see system_trash.dart).
class RecycleOnlySink : public IFileOperationProgressSink {
 public:
  bool refused_permanent_delete() const { return refused_permanent_delete_; }

  IFACEMETHODIMP QueryInterface(REFIID riid, void** object) override {
    if (riid == IID_IUnknown || riid == IID_IFileOperationProgressSink) {
      *object = static_cast<IFileOperationProgressSink*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }
  IFACEMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(::InterlockedIncrement(&references_));
  }
  IFACEMETHODIMP_(ULONG) Release() override {
    const LONG remaining = ::InterlockedDecrement(&references_);
    if (remaining == 0) {
      delete this;
    }
    return static_cast<ULONG>(remaining);
  }

  IFACEMETHODIMP PreDeleteItem(DWORD flags, IShellItem* item) override {
    if ((flags & TSF_DELETE_RECYCLE_IF_POSSIBLE) == 0) {
      refused_permanent_delete_ = true;
      return E_ABORT;
    }
    return S_OK;
  }

  IFACEMETHODIMP StartOperations() override { return S_OK; }
  IFACEMETHODIMP FinishOperations(HRESULT result) override { return S_OK; }
  IFACEMETHODIMP PreRenameItem(DWORD flags, IShellItem* item,
                               LPCWSTR new_name) override {
    return S_OK;
  }
  IFACEMETHODIMP PostRenameItem(DWORD flags, IShellItem* item,
                                LPCWSTR new_name, HRESULT result,
                                IShellItem* new_item) override {
    return S_OK;
  }
  IFACEMETHODIMP PreMoveItem(DWORD flags, IShellItem* item,
                             IShellItem* destination,
                             LPCWSTR new_name) override {
    return S_OK;
  }
  IFACEMETHODIMP PostMoveItem(DWORD flags, IShellItem* item,
                              IShellItem* destination, LPCWSTR new_name,
                              HRESULT result, IShellItem* new_item) override {
    return S_OK;
  }
  IFACEMETHODIMP PreCopyItem(DWORD flags, IShellItem* item,
                             IShellItem* destination,
                             LPCWSTR new_name) override {
    return S_OK;
  }
  IFACEMETHODIMP PostCopyItem(DWORD flags, IShellItem* item,
                              IShellItem* destination, LPCWSTR new_name,
                              HRESULT result, IShellItem* new_item) override {
    return S_OK;
  }
  IFACEMETHODIMP PostDeleteItem(DWORD flags, IShellItem* item, HRESULT result,
                                IShellItem* new_item) override {
    return S_OK;
  }
  IFACEMETHODIMP PreNewItem(DWORD flags, IShellItem* destination,
                            LPCWSTR new_name) override {
    return S_OK;
  }
  IFACEMETHODIMP PostNewItem(DWORD flags, IShellItem* destination,
                             LPCWSTR new_name, LPCWSTR template_name,
                             DWORD attributes, HRESULT result,
                             IShellItem* new_item) override {
    return S_OK;
  }
  IFACEMETHODIMP UpdateProgress(UINT total, UINT so_far) override {
    return S_OK;
  }
  IFACEMETHODIMP ResetTimer() override { return S_OK; }
  IFACEMETHODIMP PauseTimer() override { return S_OK; }
  IFACEMETHODIMP ResumeTimer() override { return S_OK; }

 private:
  LONG references_ = 1;
  bool refused_permanent_delete_ = false;
};

// Moves [path] to the Recycle Bin. Returns an empty string on success, else
// the error code and fills [message]. Synchronous: on a local disk this takes
// milliseconds, and a method channel must answer on the platform thread.
std::string RecycleFile(const std::wstring& path, std::string* message) {
  ComPtr<IShellItem> item;
  HRESULT hr = ::SHCreateItemFromParsingName(path.c_str(), nullptr,
                                             IID_PPV_ARGS(&item));
  // Already gone counts as success, as on Linux: the caller's goal is that the
  // file is not on disk.
  if (IsNotFound(hr)) {
    return std::string();
  }
  if (FAILED(hr)) {
    *message = Describe("Could not open the file", hr);
    return "trash_failed";
  }

  ComPtr<IFileOperation> operation;
  hr = ::CoCreateInstance(CLSID_FileOperation, nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&operation));
  if (FAILED(hr)) {
    *message = Describe("IFileOperation is unavailable", hr);
    return "trash_failed";
  }
  hr = operation->SetOperationFlags(FOF_ALLOWUNDO | FOF_NO_UI |
                                    FOFX_EARLYFAILURE | FOFX_RECYCLEONDELETE);
  if (FAILED(hr)) {
    *message = Describe("Could not set the operation flags", hr);
    return "trash_failed";
  }

  ComPtr<RecycleOnlySink> sink;
  sink.Attach(new RecycleOnlySink());
  DWORD cookie = 0;
  hr = operation->Advise(sink.Get(), &cookie);
  if (FAILED(hr)) {
    *message = Describe("Could not watch the operation", hr);
    return "trash_failed";
  }
  hr = operation->DeleteItem(item.Get(), nullptr);
  if (SUCCEEDED(hr)) {
    hr = operation->PerformOperations();
  }
  operation->Unadvise(cookie);

  if (sink->refused_permanent_delete()) {
    *message =
        "This file can't go to the Recycle Bin, so it was left on disk.";
    return "no_recycle_bin";
  }
  BOOL aborted = FALSE;
  operation->GetAnyOperationsAborted(&aborted);
  if (FAILED(hr) || aborted) {
    *message = Describe("The file was not moved to the Recycle Bin",
                        FAILED(hr) ? hr : E_ABORT);
    return "trash_failed";
  }
  return std::string();
}

void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "moveToTrash") {
    result->NotImplemented();
    return;
  }

  const std::string* path = nullptr;
  if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
    const auto found = args->find(flutter::EncodableValue("path"));
    if (found != args->end()) {
      path = std::get_if<std::string>(&found->second);
    }
  }
  const std::wstring wide_path = path ? Utf16FromUtf8(*path) : std::wstring();
  if (wide_path.empty()) {
    result->Error("bad_arguments", "moveToTrash requires a non-empty 'path'");
    return;
  }

  std::string message;
  const std::string error = RecycleFile(wide_path, &message);
  if (error.empty()) {
    result->Success(flutter::EncodableValue(true));
  } else {
    result->Error(error, message);
  }
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateSystemTrashChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "mydatastudio/system_trash",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(HandleMethodCall);
  return channel;
}
