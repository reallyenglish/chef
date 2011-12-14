#
# Author:: Mitsuru Y (<mitsuruy@reallyenglish.com>)
# Copyright:: Copyright (c) 2011 Real English Broadband
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/provider/package'
require 'chef/mixin/command'
require 'chef/resource/package'
require 'singleton'
require 'chef/mixin/get_source_from_package'

class Hash
  def safe_invert
    result = Hash.new{|h,key| h[key] = [] }
    self.each{|key, value|
      result[value] << key
    }
    result
  end
end

class Chef
  class Provider
    class Package
      class PkgUpgrade < Chef::Provider::Package

        # Cache for our installed and available packages

        class PkgCache
          include Chef::Mixin::Command
          include Singleton

          def initialize
            @pkg_index = Hash.new
            @pkg_index[:name] = Hash.new
            @pkg_index[:version] = Hash.new
            @pkg_index[:origin] = Hash.new
            @pkg_pkgdb = Hash.new
            @pkg_pkgdb[:name] = Hash.new
            @pkg_pkgdb[:version] = Hash.new

# Next time @pkgdb is accessed:
#  :all       - Trigger updates pkg's cache - this data is slow to gather.
#  :installed - Trigger updates only the local pkg db.
#               Used between client runs for a quick refresh.
#  :none      - Do nothing, a call to one of the reload methods is required.
            @next_refresh = :all


            # these are for subsequent runs if we are on an interval
            Chef::Client.when_run_starts do
              PkgCache.instance.reload
            end
          end

          # Cache management
          #

          def refresh
            case @next_refresh
            when :none
              return nil
            when :installed
              reset_installed
              # fast
              refresh_pkgdb
            when :all
              reset
              # medium
              refresh_pkgdb
              refresh_index 
            else
              raise ArgumentError, "Unexpected value in next_refresh: #{@next_refresh}"
            end

            # A reload method must be called before the cache is altered
            @next_refresh = :none
          end

          def refresh_index
            Chef::Log.debug("#{@new_resource} refresh index")
            run_command_with_systems_locale(
              :command => "uma fetch ftpindex"
            )
            indexfile = ""
            status = popen4("uma env") do |pid, stdin, stdout, stderr|
              stdout.each do |env_var|
                env_var.chomp!
                if env_var =~ /^PKG_INDEX='(.*)'/
                  indexfile = $1
                end
              end
            end
            IO.foreach(indexfile) do |line|
              indexline = line.split("|")
              dir = indexline[0]
              origin = indexline[1].sub(/^\/usr\/ports\//,'')
              pkg_name = pkgversion(dir)
              version = pkg_name[1]
              if version
                @pkg_index[:name][origin] = pkg_name[0]
                @pkg_index[:version][origin] = pkg_name[1]
              end
            end
            @pkg_index[:origin] = @pkg_index[:name].safe_invert
          end
        
          def refresh_pkgdb
            Chef::Log.debug("#{@new_resource} refresh pkgdb")
            status = popen4("pkg_info -Ea") do |pid, stdin, stdout, stderr|
              stdout.each do |pkgname|
                pkgname.chomp!
                pkg_name = pkgversion(pkgname)
                version = pkg_name[1]
                status = popen4("pkg_info -qo #{pkgname}") do |pid, stdin, stdout, stderr|
                  stdout.each do |line|
                    origin = line.chomp
                    @pkg_pkgdb[:name][origin] = pkg_name[0]
                    @pkg_pkgdb[:version][origin] = pkg_name[1]
                  end
                end
              end
            end
          end
        
          def pkgversion(pkgname)
            if /\s/ =~ pkgname
              return nil
        #    raise ArgumentError, "Must not contain whitespace."
            end
        
            if /^(.+)-([^-]+)$/ !~ pkgname
              return nil
        #    raise ArgumentError, "Not in due form: <name>-<version>"
            end
            name = $1
            version = splitversion($2)
            return [name, version]
          end
        
          def splitversion(pkgversion)
            if /[\s-]/ =~ pkgversion    
              return nil
        #    raise ArgumentError, "#{pkgversion}: Must not contain a '-' or whitespace."
            end
        
            if /^([^_,]+)(?:_(\d+))?(?:,(\d+))?$/ !~ pkgversion
              return nil
        #   raise ArgumentError, "#{pkgversion}: Not in due form: '<version>[_<revision>][,<epoch>]'."
             end
        
             version = $1
             revision = $2 ? $2.to_i : 0
             epoch = $3 ? $3.to_i : 0

             return pkgversion
#             return [version, revision, epoch]
          end

          def reload
            @next_refresh = :all
          end

          def reload_installed
            @next_refresh = :installed
          end

          def reset
            @pkg_index[:name].clear
            @pkg_index[:version].clear
            @pkg_index[:origin].clear
            @pkg_pkgdb[:name].clear
            @pkg_pkgdb[:version].clear
          end

          def reset_installed
            @pkg_pkgdb[:name].clear
            @pkg_pkgdb[:version].clear
          end

          # Querying the cache
          #

          def available_version(package_name)
            refresh
            origin = nil
            if package_name =~ /\//
              origin = package_name
            else
              origin = @pkg_pkgdb[:name].index(package_name)
              unless origin  # not installed
                origins = @pkg_index[:origin][package_name]
                case origins.size
                when 1
                  origin = origins.first
                when 0
                  raise Chef::Exceptions::Package, "Package #{@new_resource} not found."
                else
                  origins.each do |o|
                    if o =~ /^[^\/]*\/#{package_name}$/
                      Chef::Log.warn("#{@new_resource} more than one match and use guessed origin. consider specifying origin. ")
                      origin = o
                      break
                    end
                  end
                  unless origin
                    raise Chef::Exceptions::Package, "Package #{@new_resource} matches multiple packages which origins are #{origins.join(' ')}."
                  end
                end
              end
            end
            if origin
              @pkg_index[:version][origin]
            else
              nil
            end
          end
          alias :candidate_version :available_version

          def installed_version(package_name)
            refresh
            if package_name =~ /\//
              origin = package_name
            else
              origin = @pkg_pkgdb[:name].index(package_name)
            end
            if origin
              @pkg_pkgdb[:version][origin]
            else
              nil
            end
          end

        end # PkgCache

        include Chef::Mixin::GetSourceFromPackage

        def initialize(new_resource, run_context)
          super

          @pkg = PkgCache.instance
        end

        # Extra attributes
        #

        def flush_cache
          if @new_resource.respond_to?("flush_cache")
            @new_resource.flush_cache
          else
            { :before => false, :after => false }
          end
        end

        def agree_license
          if @new_resource.respond_to?("agree_license")
            if @new_resource.agree_license
              "yes | "
            else
              ""
            end
          else
            ""
          end
        end

        # Standard Provider methods for Parent
        #

        def load_current_resource
          if flush_cache[:before]
            @pkg.reload
          end

          @current_resource = Chef::Resource::Package.new(@new_resource.name)
          @current_resource.package_name(@new_resource.package_name)

          if @new_resource.source
            case @new_resource.source
            when /^\//
              unless ::File.exists?(@new_resource.source)
                raise Chef::Exceptions::Package, "Package #{@new_resource.name} not found: #{@new_resource.source}"
              end
            end

#            Chef::Log.debug("#{@new_resource} checking rpm status")
#            status = popen4("rpm -qp --queryformat '%{NAME} %{VERSION}-%{RELEASE}\n' #{@new_resource.source}") do |pid, stdin, stdout, stderr|
#              stdout.each do |line|
#                case line
#                when /([\w\d_.-]+)\s([\w\d_.-]+)/
#                  @current_resource.package_name($1)
#                  @new_resource.version($2)
#                end
#              end
#            end
          end

          if @new_resource.version
            new_resource = "#{@new_resource.package_name}-#{@new_resource.version}"
          else
            new_resource = "#{@new_resource.package_name}"
          end

          Chef::Log.debug("#{@new_resource} checking package info for #{new_resource}")

          installed_version = @pkg.installed_version(@new_resource.package_name)
          @current_resource.version(installed_version)

          @candidate_version = @pkg.candidate_version(@new_resource.package_name)

          Chef::Log.debug("#{@new_resource} installed version: #{installed_version || "(none)"} candidate version: " +
                          "#{@candidate_version || "(none)"}")

          @current_resource
        end

        def install_package(name, version)
          if @new_resource.source && name =~ /^\//
            run_command_with_systems_locale(
              :command => "#{agree_license} pkg_add #{expand_options(@new_resource.options)} #{@new_resource.source}"
            ) 
          else
            if name =~ /\//
              run_command_with_systems_locale(
                :command => "#{agree_license} pkg_upgrade --clean #{expand_options(@new_resource.options)} #{name}"
              )
            else
              run_command_with_systems_locale(
                :command => "#{agree_license} pkg_upgrade --clean #{expand_options(@new_resource.options)} #{name}-#{version}"
              )
            end
          end
          if flush_cache[:after]
            @pkg.reload
          else
            @pkg.reload_installed
          end
        end

        # Keep upgrades from trying to install an older candidate version. Can happen when a new
        # version is installed then removed from a repository, now the older available version
        # shows up as a viable install candidate.
        #
        # Can be done in upgrade_package but an upgraded from->to log message slips out
        #
        # Hacky - better overall solution? Custom compare in Package provider?
#        def action_upgrade
          # Ensure the candidate is newer
#          if RPMVersion.parse(candidate_version) > RPMVersion.parse(@current_resource.version)
#            super
          # Candidate is older
#          else
#            Chef::Log.debug("#{@new_resource} is at the latest version - nothing to do")
#          end
#        end

        def upgrade_package(name, version)
          install_package(name, version)
        end

        def remove_package(name, version)
          if version
            run_command_with_systems_locale(
             :command => "pkg_delete #{expand_options(@new_resource.options)} #{name}-#{version}"
            )
          else
            run_command_with_systems_locale(
             :command => "pkg_delete #{expand_options(@new_resource.options)} #{name}-#{@current_resource.version}"
            )
          end
          if flush_cache[:after]
            @pkg.reload
          else
            @pkg.reload_installed
          end
        end

        def purge_package(name, version)
          remove_package(name, version)
        end


      end
    end
  end
end
