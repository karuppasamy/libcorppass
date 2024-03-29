require 'nokogiri'
require 'corp_pass'
require 'corp_pass/util'

module CorpPass
  class InvalidUser < Error
    attr_reader :xml
    def initialize(message, xml)
      super(message)
      @xml = xml
    end
  end

  class User
    include CorpPass::Notification

    attr_reader :xml_document
    attr_reader :errors

    def initialize(xml_document)
      load_document xml_document
      @errors = []
    end

    def load_document(xml_document)
      @xml_document = xml_document
    end

    def serialize
      [xml_document]
    end

    def self.deserialize(dumped_array)
      xml = dumped_array[0]
      new(xml)
    end

    def document
      @document ||= Nokogiri::XML(@xml_document)
    end

    delegate :root, to: :document

    def validate
      return false unless xml_valid?
      return false unless xsd_valid?
      valid_root?
      valid_entity_status?
      single_eservice_result?
      eservice_results

      errors.each { |error| notify(CorpPass::Events::USER_VALIDATION_FAILURE, error) }
      errors.empty?
    end
    alias valid? validate

    def validate!
      unless validate
        # Disabling the cop because they cannot make up their mind on this!
        # And `fail` does not allow for extra parameters
        raise CorpPass::InvalidUser.new(@errors.join('; '), xml_document) # rubocop:disable Style/SignalException
      end
      true
    end

    def xml_valid?
      @xml_valid ||= begin
        valid = document.errors.empty?
        @errors << "Invalid XML Document: #{document.errors.map(&:to_s).join('; ')}" unless valid
        valid
      end
    end

    def xsd_valid?
      @xsd_valid ||= begin
                       xsd_errors = xsd.validate(document)
                       unless xsd_errors.empty?
                         @errors << "XSD Validation failed: #{xsd_errors.map(&:message).join('; ')}"
                       end
                       xsd_errors.empty?
                     end
    end

    def xsd
      Nokogiri::XML::Schema(File.read(File.dirname(__FILE__) + '/AuthAccess.xsd'))
    end

    def valid_root?
      @valid_root ||= begin
                        valid = (root.name == CorpPass::Response::AUTH_ACCESS_NAME)
                        @errors << "Provided XML Document has an invalid root: #{root.name}" unless valid
                        valid
                      end
    end

    def single_eservice_result?
      @single_eservice_result ||= begin
                                    valid = (eservice_results_element.length == 1 && eservice_count == 1)
                                    @errors << 'More than 1 eService Results were found' unless valid
                                    valid
                                  end
    end

    # User Defined Login ID
    def id
      single_textual_value_of_type_from_root 'CPID'
    end

    def user_account_type
      single_textual_value_of_type_from_root 'CPAccType'
    end

    # User NRIC/FIN
    def user_id
      single_textual_value_of_type_from_root 'CPUID'
    end
    alias to_s user_id

    def user_id_country
      single_textual_value_of_type_from_root 'CPUID_Country'
    end

    def user_id_date
      Date.parse(single_textual_value_of_type_from_root('CPUID_DATE'))
    end

    def entity_id
      single_textual_value_of_type_from_root('CPEntID')
    end

    def entity_status
      single_textual_value_of_type_from_root('CPEnt_Status')
    end

    def entity_type
      single_textual_value_of_type_from_root('CPEnt_TYPE')
    end

    def valid_entity_status?
      @valid_entity_status ||= begin
                                 valid = %w(Active Suspend Terminate).include?(entity_status)
                                 @errors << "Invalid Entity Status #{entity_status}" unless valid
                                 valid
                               end
    end

    def sp_holder?
      is_sp_holder = single_textual_value_of_type_from_root('ISSPHOLDER')
      CorpPass::Util.string_to_boolean(is_sp_holder, true_string: 'yes', false_string: 'no')
    end

    def eservice_count
      single_textual_value_of_type('ESrvc_Row_Count', result_set).to_i
    end

    def eservice_result
      eservice_results.first
    end

    def ==(other)
      other.class == self.class && other.state == state
    end
    alias eql? ==

    protected

    def state
      [xml_document]
    end

    private

    def single_textual_value_of_type_from_root(name)
      single_textual_value_of_type(name, root)
    end

    def single_textual_value_of_type(name, base)
      nodes = base.xpath("./#{name}/child::text()")
      if nodes.empty?
        nil
      else
        nodes.first.text
      end
    end

    def result_set
      root.xpath('./Result_Set[1]')
    end

    def eservice_results_element
      result_set.xpath('./ESrvc_Result')
    end

    def eservice_results
      @eservice_results ||= eservice_results_element.map do |result|
        auth_result_set_element = result.xpath('./Auth_Result_Set')
        row_count = auth_result_set_count(auth_result_set_element)
        rows = auth_result_set_element.xpath('./Row')
        unless row_count == rows.length
          @errors << "#{row_count} <Auth_Result_Set> rows was declared, but #{rows.length} found"
        end
        {
          eservice_id: single_textual_value_of_type('CPESrvcID', result),
          auth_result_set: auth_result_set(rows)
        }
      end
    end

    def auth_result_set_count(base)
      single_textual_value_of_type('Row_Count', base).to_i
    end

    def auth_result_set(rows)
      rows.map do |row|
        parameters = row.xpath('./Parameter') || []
        {
          entity_id_sub:  single_textual_value_of_type('CPEntID_SUB', row),
          role:  single_textual_value_of_type('CPRole', row),
          start_date: Date.parse(single_textual_value_of_type('StartDate', row)),
          end_date: Date.parse(single_textual_value_of_type('EndDate', row)),
          parameters:  parameters.map do |parameter|
                         name = parameter.xpath('./@name')
                         name = name.text unless name.nil?
                         {
                           name: name,
                           value: parameter.xpath('./child::text()').text
                         }
                       end
        }
      end
    end
  end
end
