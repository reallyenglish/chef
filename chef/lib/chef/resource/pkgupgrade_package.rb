#
# Author:: Mitsuru Y (<mitsuruy@reallyenglish.com>)
# Copyright:: Copyright (c) 2011 Real English Broadband, Inc.
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

require 'chef/resource/package'
require 'chef/provider/package/pkgupgrade'

class Chef
  class Resource
    class PkgupgradePackage < Chef::Resource::Package

      def initialize(name, run_context=nil)
        super
        @resource_name = :pkgupgrade_package
        @provider = Chef::Provider::Package::PkgUpgrade
        @flush_cache = { :before => false, :after => false }
        @allow_downgrade = false
      end

      def flush_cache(args={})
        if args.is_a? Array
          args.each { |arg| @flush_cache[arg] = true }
        elsif args.any?
          @flush_cache = args
        else
          @flush_cache
        end
      end

      def agree_license(arg=nil)
        set_or_return(
          :allow_downgrade,
          arg,
          :kind_of => [ TrueClass, FalseClass ]
        )
      end

    end
  end
end
