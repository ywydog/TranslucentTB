#include "dynamicdependency.hpp"
#include <wil/win32_helpers.h>

#include "../ProgramLog/error/win32.hpp"
#include "../resources/ids.h"
#include "../localization.hpp"
#include "version.hpp"
#include "../windows/window.hpp"

DynamicDependency::DynamicDependency(HMODULE hModule, Util::null_terminated_wstring_view packageFamilyName, const PACKAGE_VERSION &minVersion, bool hasPackageIdentity) :
	m_Context(nullptr)
{
	if (!hasPackageIdentity)
	{
		if (!IsApiSetImplemented("api-ms-win-appmodel-runtime-l1-1-5"))
		{
			// 当前系统（Windows 10 及更早）没有动态依赖 API（api-ms-win-appmodel-runtime-l1-1-5）。
			// 便携版已内置依赖的框架包 DLL（WinUI 与 VC 运行库），无需在运行时解析框架包，
			// 直接走本地加载路径即可。
			MessagePrint(spdlog::level::info, L"Dynamic dependency API unavailable; using bundled dependencies.");
			return;
		}

		static constexpr PackageDependencyProcessorArchitectures arch =
#if defined(_M_AMD64)
			PackageDependencyProcessorArchitectures_X64;
#elif defined(_M_ARM64)
			PackageDependencyProcessorArchitectures_Arm64;
#endif

		// we are using process dependency lifetime because we want the app to be portable, so we cannot be sure if a dependency ID created by a
		// previous instance is valid anymore - the app might have been launched on another computer. Plus I'm too lazy to implement proper storage.
		HRESULT hr = TryCreatePackageDependency(nullptr, packageFamilyName.c_str(), minVersion, arch, PackageDependencyLifetimeKind_Process, nullptr, CreatePackageDependencyOptions_None, m_dependencyId.put());
		if (FAILED(hr)) [[unlikely]]
		{
			if (hr == STATEREPOSITORY_E_DEPENDENCY_NOT_RESOLVED)
			{
				Localization::ShowLocalizedMessageBoxWithFormat(IDS_MISSING_DEPENDENCIES, MB_OK | MB_ICONWARNING | MB_SETFOREGROUND, hModule, packageFamilyName, Version::FromPackageVersion(minVersion)).join();
				ExitProcess(1);
			}
			else
			{
				HresultHandle(hr, spdlog::level::critical, L"Failed to create a dynamic dependency");
			}
		}

		wil::unique_process_heap_string packageFullName;
		hr = AddPackageDependency(m_dependencyId.get(), 0, AddPackageDependencyOptions_None, &m_Context, packageFullName.put());
		HresultVerify(hr, spdlog::level::critical, L"Failed to add a runtime dependency");
	}
}

DynamicDependency::~DynamicDependency() noexcept(false)
{
	if (m_Context)
	{
		HRESULT hr = RemovePackageDependency(m_Context);
		if (SUCCEEDED(hr))
		{
			m_Context = nullptr;
		}
		else
		{
			// we get random invalid parameter errors despite the parameter being correct.
			HresultHandle(hr, spdlog::level::info, L"Failed to remove a runtime dependency");
		}

		hr = DeletePackageDependency(m_dependencyId.get());
		HresultVerify(hr, spdlog::level::warn, L"Failed to delete a dynamic dependency");
	}
}
