module Trainer
  class TestParser
    attr_accessor :data

    attr_accessor :file_content

    attr_accessor :raw_json

    # Returns a hash with the path being the key, and the value
    # defining if the tests were successful
    def self.auto_convert(config)
      FastlaneCore::PrintTable.print_values(config: config,
                                             title: "Summary for trainer #{Trainer::VERSION}")

      report_devices_individually = config[:report_devices_individually]
      containing_dir = config[:path]

      if report_devices_individually
        files = Dir["#{containing_dir}/**/Logs/Test/*Test/*TestSummaries.plist"]
        files += Dir["#{containing_dir}/Test/*Test/*TestSummaries.plist"]
        files += Dir["#{containing_dir}/*Test/*TestSummaries.plist"]
      else
        # Xcode < 10
        files = Dir["#{containing_dir}/**/Logs/Test/*TestSummaries.plist"]
        files += Dir["#{containing_dir}/Test/*TestSummaries.plist"]
        files += Dir["#{containing_dir}/*TestSummaries.plist"]
        # Xcode 10
        files += Dir["#{containing_dir}/**/Logs/Test/*.xcresult/TestSummaries.plist"]
        files += Dir["#{containing_dir}/Test/*.xcresult/TestSummaries.plist"]
        files += Dir["#{containing_dir}/*.xcresult/TestSummaries.plist"]
        files += Dir[containing_dir] if containing_dir.end_with?(".plist") # if it's the exact path to a plist file
      end

      if files.empty?
        UI.user_error!("No test result files found in directory '#{containing_dir}', make sure the file name ends with 'TestSummaries.plist'")
      end

      return_hash = {}
      files.each do |path|
        if config[:output_directory]
          FileUtils.mkdir_p(config[:output_directory])
          filename = File.basename(path).gsub(".plist", config[:extension])
          if report_devices_individually
            filename = File.basename(File.dirname(path)) + "_" + filename
          end
          to_path = File.join(config[:output_directory], filename)
        else
          to_path = path.gsub(".plist", config[:extension])
        end

        tp = Trainer::TestParser.new(path)
        if report_devices_individually
          tp.data.each do |summary|
            summary[:target_name] = summary[:device_os_identifier] + '/' + summary[:target_name]
          end
        end

        File.write(to_path, tp.to_junit)
        puts "Successfully generated '#{to_path}'"

        return_hash[to_path] = tp.tests_successful?
      end
      return_hash
    end

    def initialize(path)
      path = File.expand_path(path)
      UI.user_error!("File not found at path '#{path}'") unless File.exist?(path)

      self.file_content = File.read(path)
      self.raw_json = Plist.parse_xml(self.file_content)
      return if self.raw_json["FormatVersion"].to_s.length.zero? # maybe that's a useless plist file

      ensure_file_valid!
      parse_content
    end

    # Returns the JUnit report as String
    def to_junit
      JunitGenerator.new(self.data).generate
    end

    # @return [Bool] were all tests successful? Is false if at least one test failed
    def tests_successful?
      self.data.collect { |a| a[:number_of_failures] }.all?(&:zero?)
    end

    private

    def ensure_file_valid!
      format_version = self.raw_json["FormatVersion"]
      supported_versions = ["1.1", "1.2"]
      UI.user_error!("Format version '#{format_version}' is not supported, must be #{supported_versions.join(', ')}") unless supported_versions.include?(format_version)
    end

    # Converts the raw plist test structure into something that's easier to enumerate
    def unfold_tests(data)
      # `data` looks like this
      # => [{"Subtests"=>
      #  [{"Subtests"=>
      #     [{"Subtests"=>
      #        [{"Duration"=>0.4,
      #          "TestIdentifier"=>"Unit/testExample()",
      #          "TestName"=>"testExample()",
      #          "TestObjectClass"=>"IDESchemeActionTestSummary",
      #          "TestStatus"=>"Success",
      #          "TestSummaryGUID"=>"4A24BFED-03E6-4FBE-BC5E-2D80023C06B4"},
      #         {"FailureSummaries"=>
      #           [{"FileName"=>"/Users/krausefx/Developer/themoji/Unit/Unit.swift",
      #             "LineNumber"=>34,
      #             "Message"=>"XCTAssertTrue failed - ",
      #             "PerformanceFailure"=>false}],
      #          "TestIdentifier"=>"Unit/testExample2()",

      tests = []
      data.each do |current_hash|
        if current_hash["Subtests"]
          tests += unfold_tests(current_hash["Subtests"])
        end
        if current_hash["TestStatus"]
          tests << current_hash
        end
      end
      return tests
    end

    # Convert the Hashes and Arrays in something more useful
    def parse_content
      target_device = self.raw_json["RunDestination"]["TargetDevice"]
      device_os_identifier = [
        target_device["Name"],
        target_device["Platform"]["Name"],
        target_device["OperatingSystemVersion"]
      ].join(' ')
      self.data = self.raw_json["TestableSummaries"].collect do |testable_summary|
        summary_row = {
          project_path: testable_summary["ProjectPath"],
          device_os_identifier: device_os_identifier,
          target_name: testable_summary["TargetName"],
          test_name: testable_summary["TestName"],
          duration: testable_summary["Tests"].map { |current_test| current_test["Duration"] }.inject(:+),
          tests: unfold_tests(testable_summary["Tests"]).collect do |current_test|
            current_row = {
              identifier: current_test["TestIdentifier"],
              test_group: current_test["TestIdentifier"].split("/")[0..-2].join("."),
              name: current_test["TestName"],
              object_class: current_test["TestObjectClass"],
              status: current_test["TestStatus"],
              guid: current_test["TestSummaryGUID"],
              duration: current_test["Duration"]
            }
            require 'pp'
            pp current_test
            if current_test["FailureSummaries"]
              current_row[:failures] = current_test["FailureSummaries"].collect do |current_failure|
                {
                  file_name: current_failure['FileName'],
                  line_number: current_failure['LineNumber'],
                  message: current_failure['Message'],
                  performance_failure: current_failure['PerformanceFailure'],
                  failure_message: "#{current_failure['Message']} (#{current_failure['FileName']}:#{current_failure['LineNumber']})"
                }
              end
            end
            current_row
          end
        }
        summary_row[:number_of_tests] = summary_row[:tests].count
        summary_row[:number_of_failures] = summary_row[:tests].find_all { |a| (a[:failures] || []).count > 0 }.count
        summary_row
      end
    end
  end
end
