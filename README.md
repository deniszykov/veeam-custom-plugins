# Veeam Custom Plugins

This repository contains community-driven custom plugins for use with the Veeam Service Provider Console. It is intended to provide a central place for plugins that can help automate, customize, and extend Veeam operations. Plugins in this repository are not created by Veeam R&D or validated by Veeam Q&A. They are maintained by community members which may or not be Veeam employees.

## ⚙️ How it works

Every plugin lives in its own top-level `vspc-*` directory (for example `vspc-autotask-plugin/`). A plugin ships as a **NuGet package** (`.nupkg`) used as an *envelope*: the package carries the plugin's self-contained service executable, its web UI, and the VSPC plugin manifest. NuGet is not used as a code dependency here — it is only the packaging/transport format that the Veeam Service Provider Console catalog understands.

### Build

A [GitHub Actions workflow](.github/workflows/build-plugins.yml) runs on every push to `main` that touches a `vspc-*/` directory. For each plugin it runs the plugin's own `source/build.ps1`, which executes the unit tests, then publishes, packs, and signs the `.nupkg`, and collects the produced packages.

### Static NuGet feed

The built packages are published into a **static NuGet repository** under [`/repository`](repository/) using [Sleet](https://github.com/emgarten/Sleet), configured in [`sleet.json`](sleet.json). The feed is regenerated deterministically and committed back to this repository by the same workflow.

The feed is served over HTTPS at:

```
https://raw.githubusercontent.com/deniszykov/veeam-custom-plugins/main/repository/index.json
```

Add it as a NuGet package source to browse or install the plugins:

```xml
<configuration>
  <packageSources>
    <add key="vspc-plugins" value="https://raw.githubusercontent.com/deniszykov/veeam-custom-plugins/main/repository/index.json" />
  </packageSources>
</configuration>
```

The workflow pushes the regenerated feed back to `main` and resolves any concurrent feed change in its own favor, so `/repository/` always reflects the current plugin sources.

## 📗 Documentation

Documentation, including usage instructions, can be found within each plugin directory.

## ✍ Contributions

We welcome contributions from the community! We encourage you to create [issues](https://github.com/VeeamHub/veeam-custom-plugins/issues/new/choose) for bugs, feature requests, and enhancement ideas, and submit pull requests. For more detailed information, refer to our [Contributing Guide](CONTRIBUTING.md).

## 🤝🏾 License

* [MIT License](LICENSE)

## 🤔 Questions

If you have any questions or something is unclear, please don't hesitate to [create an issue](https://github.com/VeeamHub/veeam-custom-plugins/issues/new/choose) and let us know!
