/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATE INPUTS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)

// Validate input parameters
WorkflowBamtofastq.initialise(params, log)

// Check input path parameters to see if they exist
def checkPathParamList = [
    params.fasta,
    params.fasta_fai,
    params.input,
    params.multiqc_config
    ]

for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

// Check mandatory parameters
if (params.input) { ch_input = extract_csv(file(params.input, checkIfExists: true)) } else { exit 1, 'Input samplesheet not specified!' }


// Initialize file channels based on params
fasta     = params.fasta     ? Channel.fromPath(params.fasta).collect()      : Channel.value([])
fasta_fai = params.fasta_fai ? Channel.fromPath(params.fasta_fai).collect()  : Channel.value([])

// Initialize value channels based on params
chr       = params.chr       ?: Channel.empty()

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ERROR MESSAGES AND WARNINGS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CHECK_IF_PAIRED_END                                       } from '../modules/local/check_paired_end'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//
include { FASTQC  as  FASTQC_POST_CONVERSION                        } from '../modules/nf-core/fastqc/main'
include { SAMTOOLS_VIEW as SAMTOOLS_CHR                             } from '../modules/nf-core/samtools/view/main'
include { SAMTOOLS_VIEW as SAMTOOLS_PE                              } from '../modules/nf-core/samtools/view/main'
include { SAMTOOLS_INDEX as SAMTOOLS_CHR_INDEX                      } from '../modules/nf-core/samtools/index/main'
include { SAMTOOLS_COLLATEFASTQ as SAMTOOLS_COLLATEFASTQ_SINGLE_END } from '../modules/nf-core/samtools/collatefastq/main'

include { MULTIQC                                                   } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS                               } from '../modules/nf-core/custom/dumpsoftwareversions/main'

//
// SUBWORKFLOWS: Installed directly from subworkflows/local
//

include { PREPARE_INDICES                                           } from '../subworkflows/local/prepare_indices'
include { PRE_CONVERSION_QC                                         } from '../subworkflows/local/pre_conversion_qc'
include { ALIGNMENT_TO_FASTQ                                        } from '../subworkflows/local/alignment_to_fastq'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow BAMTOFASTQ {

    ch_versions = Channel.empty()

    // SUBWORKFLOW: Prepare indices bai/crai/fai if not provided
    PREPARE_INDICES(
        ch_input,
        fasta
    )

    ch_versions = ch_versions.mix(PREPARE_INDICES.out.versions)

    fasta_fai = params.fasta ? params.fasta_fai ? Channel.fromPath(params.fasta_fai).collect() : PREPARE_INDICES.out.fasta_fai : []

    ch_input = PREPARE_INDICES.out.ch_input_indexed

    // SUBWORKFLOW: Pre conversion QC and stats

    PRE_CONVERSION_QC(
        ch_input,
        fasta
    )

    ch_versions = ch_versions.mix(PRE_CONVERSION_QC.out.versions)

    // MODULE: Check if SINGLE or PAIRED-END

    CHECK_IF_PAIRED_END(ch_input, fasta)

    ch_paired_end = ch_input.join(CHECK_IF_PAIRED_END.out.paired_end)
    ch_single_end = ch_input.join(CHECK_IF_PAIRED_END.out.single_end)

    // Combine channels into new input channel for conversion + add info about single/paired to meta map
    ch_input_new = ch_single_end.map{ meta, bam, bai, txt ->
            [ [ id : meta.id,
            filetype : meta.filetype,
            single_end : true ],
            bam,
            bai
            ] }
        .mix(ch_paired_end.map{ meta, bam, bai, txt ->
            [ [ id : meta.id,
            filetype : meta.filetype,
            single_end : false ],
            bam,
            bai
            ] })

    ch_versions = ch_versions.mix(CHECK_IF_PAIRED_END.out.versions)


    // Extract only reads mapping to a chromosome
    if (params.chr) {

        SAMTOOLS_CHR(ch_input_new, fasta, [])

        samtools_chr_out = Channel.empty().mix( SAMTOOLS_CHR.out.bam,
                                                SAMTOOLS_CHR.out.cram)
        SAMTOOLS_CHR_INDEX(samtools_chr_out)
        ch_input_chr = samtools_chr_out.join(Channel.empty().mix( SAMTOOLS_CHR_INDEX.out.bai,
                                                                SAMTOOLS_CHR_INDEX.out.crai ))

        // Add chr names to id
        ch_input_new = ch_input_chr.map{ it ->
                new_id = it[1].baseName
                [[
                    id : new_id,
                    filetype : it[0].filetype,
                    single_end: it[0].single_end
                ],
                it[1],
                it[2]] }

        ch_versions = ch_versions.mix(SAMTOOLS_CHR.out.versions)
        ch_versions = ch_versions.mix(SAMTOOLS_CHR_INDEX.out.versions)

    }

    // MODULE: SINGLE-END Alignment to FastQ (SortExtractSingleEnd)
    def interleave = false

    ch_input_new.branch{
        ch_single:  it[0].single_end == true
        ch_paired:  it[0].single_end == false
    }.set{conversion_input}

    // Module needs info about single-endedness
    SAMTOOLS_COLLATEFASTQ_SINGLE_END(
        conversion_input.ch_single.map{ it -> [ it[0], it[1] ]}, // meta, bam/cram
        fasta.map{ it ->                                         // meta, fasta
            def new_id = ""
            if(it) {
                new_id = it[0].baseName
            }
            [[id:new_id], it] },
        interleave)

    ch_versions = ch_versions.mix(SAMTOOLS_COLLATEFASTQ_SINGLE_END.out.versions)

    //
    // SUBWORKFLOW: PAIRED-END Alignment to FastQ
    //

    ALIGNMENT_TO_FASTQ (
        conversion_input.ch_paired,
        fasta,
        fasta_fai
    )

    ch_versions = ch_versions.mix(ALIGNMENT_TO_FASTQ.out.versions)


    // MODULE: FastQC - Post conversion QC
    ch_reads_post_qc = Channel.empty().mix(SAMTOOLS_COLLATEFASTQ_SINGLE_END.out.fastq_singleton, ALIGNMENT_TO_FASTQ.out.reads)

    FASTQC_POST_CONVERSION(ch_reads_post_qc)

    ch_versions = ch_versions.mix(FASTQC_POST_CONVERSION.out.versions)

    //  MODULE: Software versions
    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowBamtofastq.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    methods_description    = WorkflowBamtofastq.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(PRE_CONVERSION_QC.out.flagstat.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(PRE_CONVERSION_QC.out.idxstats.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(PRE_CONVERSION_QC.out.stats.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(PRE_CONVERSION_QC.out.zip.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC_POST_CONVERSION.out.zip.collect{it[1]}.ifEmpty([]))


    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )
    multiqc_report = MULTIQC.out.report.toList()
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
// Function to extract information (meta data + file(s)) from csv file(s)
def extract_csv(csv_file) {

    // check that the sample sheet is not 1 line or less, because it'll skip all subsequent checks if so.
    file(csv_file).withReader('UTF-8') { reader ->
        def line, numberOfLinesInSampleSheet = 0;
        while ((line = reader.readLine()) != null) {numberOfLinesInSampleSheet++}
        if (numberOfLinesInSampleSheet < 2) {
            error("Samplesheet had less than two lines. The sample sheet must be a csv file with a header, so at least two lines.")
        }
    }
    Channel.from(csv_file).splitCsv(header: true)
        .map{ row ->
            if ( !row.sample_id ) {  // This also handles the case where the lane is left as an empty string
                error('The sample sheet should specify a sample_id for each row.\n' + row.toString())
            }
            if ( !row.mapped ) {  // This also handles the case where the lane is left as an empty string
                error('The sample sheet should specify a mapped file for each row.\n' + row.toString())
            }
            if (!row.file_type) {  // This also handles the case where the lane is left as an empty string
                error('The sample sheet should specify a file_type for each row, valid values are bam/cram.\n' + row.toString())
            }
            if (!(row.file_type == "bam" || row.file_type == "cram")) {
                error('The file_type for the row below is neither "bam" nor "cram". Please correct this.\n' + row.toString() )
            }
            if (row.file_type != file(row.mapped).getExtension().toString()) {
                error('The file extension does not fit the specified file_type.\n' + row.toString() )
            }


            // init meta map
            def meta = [:]

            meta.id       = "${row.sample_id}".toString()
            def mapped    = file(row.mapped, checkIfExists: true)
            def index     = row.index ? file(row.index, checkIfExists: true) : []
            meta.filetype = "${row.file_type}".toString()
            meta.index    = row.index ? true : false

            return [meta, mapped, index]

            }

}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
